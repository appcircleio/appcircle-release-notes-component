# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'yaml'
require 'rbconfig'

MAIN_RB        = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT   = File.dirname(MAIN_RB)
COMPONENT_YAML = File.join(PROJECT_ROOT, 'component.yaml')

# If the top-level guard is ever lost, requiring main.rb runs the step and its
# `exit 0` would end this suite with a false green. Fail loudly instead.
begin
  require MAIN_RB
rescue SystemExit => e
  abort "main.rb ran its step on require (exit #{e.status}); top-level code must stay inside `if __FILE__ == $PROGRAM_NAME`."
end

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Directory where child processes drop their coverage snapshots, so the report
# reflects the guarded top-level block as well as the in-process function.
COVERAGE_DIR = Dir.mktmpdir('release_notes_cov')

# Preloaded into every child with `ruby -r<helper> main.rb`, which keeps
# main.rb as $PROGRAM_NAME so its top-level guard still fires.
COVERAGE_HELPER = File.join(COVERAGE_DIR, 'cov_helper.rb')
File.write(COVERAGE_HELPER, <<~RUBY)
  require 'coverage'
  Coverage.start
  at_exit do
    dir = ENV['AC_TEST_COVERAGE_DIR']
    next if dir.nil? || dir.empty?

    result = begin
      Coverage.result(stop: false, clear: false)
    rescue ArgumentError
      Coverage.result
    end
    target = result.keys.find { |p| p.to_s.end_with?('main.rb') }
    next if target.nil?

    counts = result[target].map { |c| c.nil? ? '-' : c }.join(',')
    File.write(File.join(dir, "cov-\#{Process.pid}.txt"), counts)
  end
RUBY

# Merge every child snapshot into a single line-count array.
def subprocess_coverage
  Dir.glob(File.join(COVERAGE_DIR, 'cov-*.txt')).each_with_object([]) do |file, acc|
    File.read(file).split(',').each_with_index do |cell, i|
      next if cell == '-'

      acc[i] = (acc[i] || 0) + cell.to_i
    end
  end
end

# Every variable main.rb (or the default template) reads. Keys not passed to
# run_main are explicitly UNSET in the child, so the parent's environment can
# never leak into a test.
STEP_ENV_KEYS = %w[
  AC_RELEASE_NOTES_PATH AC_RELEASE_NOTES_TEMPLATE AC_REPOSITORY_DIR
  AC_OUTPUT_DIR AC_GIT_COMMIT AC_GIT_BRANCH RN_TEST_VALUE
].freeze

# Run main.rb in a subprocess with the given ENV overrides, from `chdir`.
def run_main(env = {}, chdir:)
  child_env = STEP_ENV_KEYS.to_h { |k| [k, nil] }.merge(env)
  child_env['AC_TEST_COVERAGE_DIR'] = COVERAGE_DIR
  Open3.capture3(child_env, RbConfig.ruby, "-r#{COVERAGE_HELPER}", MAIN_RB, chdir: chdir)
end

# The default AC_RELEASE_NOTES_TEMPLATE shipped in component.yaml.
def default_template
  YAML.safe_load(File.read(COMPONENT_YAML))['inputs']
      .find { |i| i['key'] == 'AC_RELEASE_NOTES_TEMPLATE' }['defaultValue']
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe 'main.rb loading contract' do
  let(:tmpdir) { Dir.mktmpdir('release_notes_load_test') }
  after { FileUtils.rm_rf(tmpdir) }

  it 'defines env_has_key when required' do
    expect(defined?(env_has_key)).to eq('method')
  end

  it 'does not run the step when required, even with every input set' do
    out_dir = File.join(tmpdir, 'out')
    FileUtils.mkdir_p(out_dir)
    File.write(File.join(tmpdir, 'notes.txt'), 'notes')
    env = {
      'AC_RELEASE_NOTES_PATH'     => 'notes.txt',
      'AC_RELEASE_NOTES_TEMPLATE' => 'template',
      'AC_REPOSITORY_DIR'         => tmpdir,
      'AC_OUTPUT_DIR'             => out_dir
    }
    out, err, status = Open3.capture3(env, RbConfig.ruby, '-e', "require #{MAIN_RB.dump}; puts 'loaded'", chdir: tmpdir)
    expect(status.exitstatus).to eq(0), err
    expect(out).to eq("loaded\n")
    expect(Dir.children(out_dir)).to be_empty
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#env_has_key' do
  around do |example|
    old = ENV['_RN_TEST_VAR']
    example.run
  ensure
    ENV['_RN_TEST_VAR'] = old
  end

  context 'positive' do
    it 'returns the value when the key is set' do
      ENV['_RN_TEST_VAR'] = '/path/to/output'
      expect(env_has_key('_RN_TEST_VAR')).to eq('/path/to/output')
    end

    it 'returns a whitespace-only value as-is' do
      ENV['_RN_TEST_VAR'] = '   '
      expect(env_has_key('_RN_TEST_VAR')).to eq('   ')
    end

    it 'does not write to stderr when the key is set' do
      ENV['_RN_TEST_VAR'] = 'value'
      expect { env_has_key('_RN_TEST_VAR') }.not_to output.to_stderr
    end
  end

  context 'negative' do
    it 'aborts with exit status 1 when the key is missing' do
      ENV.delete('_RN_TEST_VAR')
      expect { env_has_key('_RN_TEST_VAR') }.to raise_error(SystemExit) { |e|
        expect(e.status).to eq(1)
        expect(e.message).to eq('Missing _RN_TEST_VAR.')
      }.and output("Missing _RN_TEST_VAR.\n").to_stderr
    end

    it 'aborts with exit status 1 when the value is an empty string' do
      ENV['_RN_TEST_VAR'] = ''
      expect { env_has_key('_RN_TEST_VAR') }.to raise_error(SystemExit) { |e|
        expect(e.status).to eq(1)
        expect(e.message).to eq('Missing _RN_TEST_VAR.')
      }.and output("Missing _RN_TEST_VAR.\n").to_stderr
    end

    it 'raises TypeError for a nil key' do
      expect { env_has_key(nil) }.to raise_error(TypeError)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'ENV validation: AC_RELEASE_NOTES_PATH and AC_RELEASE_NOTES_TEMPLATE' do
  let(:tmpdir)  { Dir.mktmpdir('release_notes_env_test') }
  let(:out_dir) { File.join(tmpdir, 'out').tap { |d| FileUtils.mkdir_p(d) } }
  after { FileUtils.rm_rf(tmpdir) }

  NO_NOTES_MESSAGE = 'No release notes given. Please provide a release notes file or set the template.'

  {
    'both missing'                       => {},
    'path empty, template missing'       => { 'AC_RELEASE_NOTES_PATH' => '' },
    'path missing, template empty'       => { 'AC_RELEASE_NOTES_TEMPLATE' => '' },
    'both empty'                         => { 'AC_RELEASE_NOTES_PATH' => '', 'AC_RELEASE_NOTES_TEMPLATE' => '' }
  }.each do |label, env|
    it "#{label}: exits 0 with the 'no release notes' message and writes nothing" do
      out, err, status = run_main(env.merge('AC_OUTPUT_DIR' => out_dir, 'AC_REPOSITORY_DIR' => tmpdir), chdir: tmpdir)
      expect(status.exitstatus).to eq(0), err
      expect(out).to eq("#{NO_NOTES_MESSAGE}\n")
      expect(err).to be_empty
      expect(Dir.children(out_dir)).to be_empty
    end
  end

  it 'does not require AC_OUTPUT_DIR or AC_REPOSITORY_DIR when neither input is given' do
    out, err, status = run_main({}, chdir: tmpdir)
    expect(status.exitstatus).to eq(0), err
    expect(out).to include(NO_NOTES_MESSAGE)
    expect(err).not_to match(/Missing/)
  end

  it 'falls through to the template when AC_RELEASE_NOTES_PATH is missing' do
    _out, err, status = run_main({ 'AC_RELEASE_NOTES_TEMPLATE' => 'from template', 'AC_OUTPUT_DIR' => out_dir }, chdir: tmpdir)
    expect(status.exitstatus).to eq(0), err
    expect(File.read(File.join(out_dir, 'release-notes.txt'))).to eq("from template\n")
  end

  it 'falls through to the template when AC_RELEASE_NOTES_PATH is empty' do
    _out, err, status = run_main(
      { 'AC_RELEASE_NOTES_PATH' => '', 'AC_RELEASE_NOTES_TEMPLATE' => 'from template', 'AC_OUTPUT_DIR' => out_dir },
      chdir: tmpdir
    )
    expect(status.exitstatus).to eq(0), err
    expect(File.read(File.join(out_dir, 'release-notes.txt'))).to eq("from template\n")
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'Release notes file (AC_RELEASE_NOTES_PATH)' do
  let(:tmpdir)   { Dir.mktmpdir('release_notes_path_test') }
  let(:repo_dir) { File.join(tmpdir, 'repo').tap { |d| FileUtils.mkdir_p(d) } }
  let(:out_dir)  { File.join(tmpdir, 'out').tap { |d| FileUtils.mkdir_p(d) } }
  let(:output)   { File.join(out_dir, 'release-notes.txt') }
  let(:notes)    { "What's new\n- Fixed a crash\n- Ünïcödé ✓\n" }
  let(:base_env) do
    {
      'AC_RELEASE_NOTES_PATH' => 'notes.txt',
      'AC_REPOSITORY_DIR'     => repo_dir,
      'AC_OUTPUT_DIR'         => out_dir
    }
  end

  before { File.write(File.join(repo_dir, 'notes.txt'), notes) }
  after  { FileUtils.rm_rf(tmpdir) }

  context 'positive' do
    it 'copies the file relative to AC_REPOSITORY_DIR into AC_OUTPUT_DIR/release-notes.txt' do
      out, err, status = run_main(base_env, chdir: tmpdir)
      expect(status.exitstatus).to eq(0), err
      expect(err).to be_empty
      expect(File.binread(output)).to eq(notes.b)
      expect(out).to eq("Release notes: #{File.join(repo_dir, 'notes.txt')} copied to #{output}\n")
    end

    it 'supports nested and ./-prefixed relative paths' do
      FileUtils.mkdir_p(File.join(repo_dir, 'docs'))
      File.write(File.join(repo_dir, 'docs', 'changelog.md'), 'nested')

      _out, err, status = run_main(base_env.merge('AC_RELEASE_NOTES_PATH' => './docs/changelog.md'), chdir: tmpdir)
      expect(status.exitstatus).to eq(0), err
      expect(File.read(output)).to eq('nested')
    end

    it 'uses an absolute AC_RELEASE_NOTES_PATH as-is, ignoring AC_REPOSITORY_DIR' do
      absolute = File.join(tmpdir, 'elsewhere.txt')
      File.write(absolute, 'absolute notes')

      out, err, status = run_main(base_env.merge('AC_RELEASE_NOTES_PATH' => absolute), chdir: tmpdir)
      expect(status.exitstatus).to eq(0), err
      expect(File.read(output)).to eq('absolute notes')
      expect(out).to include("Release notes: #{absolute} copied to")
    end

    it 'takes precedence over AC_RELEASE_NOTES_TEMPLATE' do
      out, err, status = run_main(base_env.merge('AC_RELEASE_NOTES_TEMPLATE' => 'TEMPLATE <%= 1 + 1 %>'), chdir: tmpdir)
      expect(status.exitstatus).to eq(0), err
      expect(File.binread(output)).to eq(notes.b)
      expect(out).not_to include('Auto-generating')
    end

    it 'overwrites an existing release-notes.txt' do
      File.write(output, 'stale content')
      _out, err, status = run_main(base_env, chdir: tmpdir)
      expect(status.exitstatus).to eq(0), err
      expect(File.binread(output)).to eq(notes.b)
    end

    it 'copies an empty file as an empty release-notes.txt' do
      File.write(File.join(repo_dir, 'notes.txt'), '')
      _out, err, status = run_main(base_env, chdir: tmpdir)
      expect(status.exitstatus).to eq(0), err
      expect(File.size(output)).to eq(0)
    end

    it 'handles paths containing spaces' do
      spaced_repo = File.join(tmpdir, 'my repo').tap { |d| FileUtils.mkdir_p(d) }
      spaced_out  = File.join(tmpdir, 'my out').tap { |d| FileUtils.mkdir_p(d) }
      File.write(File.join(spaced_repo, 'release notes.txt'), 'spaced')

      _out, err, status = run_main(
        { 'AC_RELEASE_NOTES_PATH' => 'release notes.txt', 'AC_REPOSITORY_DIR' => spaced_repo, 'AC_OUTPUT_DIR' => spaced_out },
        chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0), err
      expect(File.read(File.join(spaced_out, 'release-notes.txt'))).to eq('spaced')
    end

    it 'resolves a relative AC_OUTPUT_DIR against the working directory' do
      out, err, status = run_main(base_env.merge('AC_OUTPUT_DIR' => 'out'), chdir: tmpdir)
      expect(status.exitstatus).to eq(0), err
      expect(File.binread(output)).to eq(notes.b)
      expect(out).to include("copied to #{File.join(File.realpath(tmpdir), 'out', 'release-notes.txt')}")
    end
  end

  context 'negative' do
    shared_examples 'a failing validation' do |key, env|
      it "exits non-zero with 'Missing #{key}.' and writes nothing" do
        out, err, status = run_main(base_env.merge(env), chdir: tmpdir)
        expect(status.exitstatus).not_to eq(0)
        expect(err).to include("Missing #{key}.")
        expect(out).not_to include('copied to')
        expect(File).not_to exist(output)
      end
    end

    context 'AC_REPOSITORY_DIR is missing' do
      include_examples 'a failing validation', 'AC_REPOSITORY_DIR', { 'AC_REPOSITORY_DIR' => nil }
    end

    context 'AC_REPOSITORY_DIR is empty string' do
      include_examples 'a failing validation', 'AC_REPOSITORY_DIR', { 'AC_REPOSITORY_DIR' => '' }
    end

    context 'AC_OUTPUT_DIR is missing' do
      include_examples 'a failing validation', 'AC_OUTPUT_DIR', { 'AC_OUTPUT_DIR' => nil }
    end

    context 'AC_OUTPUT_DIR is empty string' do
      include_examples 'a failing validation', 'AC_OUTPUT_DIR', { 'AC_OUTPUT_DIR' => '' }
    end

    it 'validates AC_REPOSITORY_DIR before AC_OUTPUT_DIR' do
      _out, err, status = run_main(base_env.merge('AC_REPOSITORY_DIR' => nil, 'AC_OUTPUT_DIR' => nil), chdir: tmpdir)
      expect(status.exitstatus).to eq(1)
      expect(err).to eq("Missing AC_REPOSITORY_DIR.\n")
    end

    it 'does not fall back to the template when a required variable is missing' do
      out, err, status = run_main(
        base_env.merge('AC_REPOSITORY_DIR' => nil, 'AC_RELEASE_NOTES_TEMPLATE' => 'fallback'),
        chdir: tmpdir
      )
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('Missing AC_REPOSITORY_DIR.')
      expect(out).not_to include('Auto-generating')
      expect(File).not_to exist(output)
    end

    it 'fails with Errno::ENOENT when the release notes file does not exist' do
      out, err, status = run_main(base_env.merge('AC_RELEASE_NOTES_PATH' => 'missing.txt'), chdir: tmpdir)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Errno::ENOENT/)
      expect(err).to include(File.join(repo_dir, 'missing.txt'))
      expect(out).not_to include('copied to')
      expect(File).not_to exist(output)
    end

    it 'fails with Errno::ENOENT when AC_REPOSITORY_DIR does not exist' do
      _out, err, status = run_main(base_env.merge('AC_REPOSITORY_DIR' => File.join(tmpdir, 'nope')), chdir: tmpdir)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Errno::ENOENT/)
      expect(File).not_to exist(output)
    end

    it 'fails with Errno::ENOENT when AC_OUTPUT_DIR does not exist' do
      missing_out = File.join(tmpdir, 'no-such-dir')
      out, err, status = run_main(base_env.merge('AC_OUTPUT_DIR' => missing_out), chdir: tmpdir)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Errno::ENOENT/)
      expect(out).not_to include('copied to')
      expect(File).not_to exist(missing_out)
    end

    it 'fails when AC_RELEASE_NOTES_PATH points to a directory' do
      FileUtils.mkdir_p(File.join(repo_dir, 'notes-dir'))
      out, err, status = run_main(base_env.merge('AC_RELEASE_NOTES_PATH' => 'notes-dir'), chdir: tmpdir)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Errno::EISDIR/)
      expect(out).not_to include('copied to')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'Release notes template (AC_RELEASE_NOTES_TEMPLATE)' do
  let(:tmpdir)   { Dir.mktmpdir('release_notes_template_test') }
  let(:out_dir)  { File.join(tmpdir, 'out').tap { |d| FileUtils.mkdir_p(d) } }
  let(:output)   { File.join(out_dir, 'release-notes.txt') }
  let(:base_env) { { 'AC_OUTPUT_DIR' => out_dir } }

  after { FileUtils.rm_rf(tmpdir) }

  def render(template, env = {})
    run_main(base_env.merge('AC_RELEASE_NOTES_TEMPLATE' => template).merge(env), chdir: tmpdir)
  end

  context 'positive' do
    it 'writes a plain-text template followed by a newline' do
      out, err, status = render('Plain release notes')
      expect(status.exitstatus).to eq(0), err
      expect(err).to be_empty
      expect(File.read(output)).to eq("Plain release notes\n")
      expect(out).to eq("Auto-generating release notes...\nRelease notes generated and copied to #{output}\n")
    end

    it 'does not add a second newline when the template already ends with one' do
      _out, err, status = render("Line 1\nLine 2\n")
      expect(status.exitstatus).to eq(0), err
      expect(File.read(output)).to eq("Line 1\nLine 2\n")
    end

    it 'evaluates <%= %> expressions, including ENV lookups' do
      _out, err, status = render("Value: <%= ENV['RN_TEST_VALUE'] %>, Sum: <%= 2 + 3 %>", 'RN_TEST_VALUE' => 'hello')
      expect(status.exitstatus).to eq(0), err
      expect(File.read(output)).to eq("Value: hello, Sum: 5\n")
    end

    it "runs lines starting with '%' as Ruby code (trim_mode '%')" do
      _out, err, status = render("% 3.times do |i|\nItem <%= i %>\n% end\n")
      expect(status.exitstatus).to eq(0), err
      expect(File.read(output)).to eq("Item 0\nItem 1\nItem 2\n")
    end

    it "drops the newline after lines that are a single <% %> tag (trim_mode '<>')" do
      template = "Header\n<% if ENV['RN_TEST_VALUE'] %>\nShown\n<% end %>\nFooter\n"

      _out, err, status = render(template, 'RN_TEST_VALUE' => 'yes')
      expect(status.exitstatus).to eq(0), err
      expect(File.read(output)).to eq("Header\nShown\nFooter\n")

      _out, err, status = render(template)
      expect(status.exitstatus).to eq(0), err
      expect(File.read(output)).to eq("Header\nFooter\n")
    end

    it 'renders the default template from component.yaml' do
      commit = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
      _out, err, status = render(default_template, 'AC_GIT_COMMIT' => commit)
      expect(status.exitstatus).to eq(0), err

      content = File.read(output)
      expect(content).to include("Commit Hash: #{commit[0..6]}\n")
      expect(content).not_to include(commit[0..7])
      expect(content).not_to include('Please check our documentation') # ERB comment removed
      # $VARS are expanded by Appcircle before the step runs, not by main.rb.
      expect(content).to include('Branch: $AC_GIT_BRANCH')
      expect(content).to include('Build Workflow: $AC_WORKFLOW_NAME')
    end

    it 'preserves multibyte UTF-8 content' do
      _out, err, status = render('Sürüm notları: ✓ 🚀')
      expect(status.exitstatus).to eq(0), err
      expect(File.read(output, encoding: 'UTF-8')).to eq("Sürüm notları: ✓ 🚀\n")
    end

    it 'overwrites an existing release-notes.txt' do
      File.write(output, "stale\ncontent\nthat is longer\n")
      _out, err, status = render('fresh')
      expect(status.exitstatus).to eq(0), err
      expect(File.read(output)).to eq("fresh\n")
    end

    it 'does not require AC_REPOSITORY_DIR' do
      _out, err, status = render('no repo needed', 'AC_REPOSITORY_DIR' => nil)
      expect(status.exitstatus).to eq(0), err
      expect(err).not_to include('Missing')
      expect(File.read(output)).to eq("no repo needed\n")
    end

    it 'resolves a relative AC_OUTPUT_DIR against the working directory' do
      out, err, status = render('relative', 'AC_OUTPUT_DIR' => 'out')
      expect(status.exitstatus).to eq(0), err
      expect(File.read(output)).to eq("relative\n")
      expect(out).to include("copied to #{File.join(File.realpath(tmpdir), 'out', 'release-notes.txt')}")
    end
  end

  context 'negative' do
    shared_examples 'a failing validation' do |env|
      it "exits non-zero with 'Missing AC_OUTPUT_DIR.' and writes nothing" do
        out, err, status = render('Some notes', env)
        expect(status.exitstatus).to eq(1)
        expect(err).to eq("Missing AC_OUTPUT_DIR.\n")
        expect(out).to eq("Auto-generating release notes...\n")
        expect(Dir.children(out_dir)).to be_empty
      end
    end

    context 'AC_OUTPUT_DIR is missing' do
      include_examples 'a failing validation', { 'AC_OUTPUT_DIR' => nil }
    end

    context 'AC_OUTPUT_DIR is empty string' do
      include_examples 'a failing validation', { 'AC_OUTPUT_DIR' => '' }
    end

    it 'fails with Errno::ENOENT when AC_OUTPUT_DIR does not exist' do
      missing_out = File.join(tmpdir, 'no-such-dir')
      out, err, status = render('notes', 'AC_OUTPUT_DIR' => missing_out)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Errno::ENOENT/)
      expect(out).not_to include('copied to')
      expect(File).not_to exist(missing_out)
    end

    it 'fails with a SyntaxError for a malformed template' do
      out, err, status = render('Broken <%= 1 + %>')
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/SyntaxError/)
      expect(out).not_to include('copied to')
    end

    it 'fails and reports the error raised by template code' do
      out, err, status = render("<% raise 'template boom' %>")
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('template boom')
      expect(out).not_to include('copied to')
    end

    it 'fails with NoMethodError when the default template runs without AC_GIT_COMMIT' do
      out, err, status = render(default_template)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/NoMethodError/)
      expect(out).not_to include('copied to')
    end

    it 'leaves an empty release-notes.txt behind when rendering fails (file is opened before rendering)' do
      _out, _err, status = render("<% raise 'template boom' %>")
      expect(status.exitstatus).not_to eq(0)
      expect(File).to exist(output)
      expect(File.size(output)).to eq(0)
    end
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  # Fold in the counts collected from the `ruby main.rb` subprocesses so the
  # guarded top-level block is not reported as dead code.
  child     = subprocess_coverage
  data      = result[main_path].each_with_index.map do |count, idx|
    count.nil? ? nil : count + (child[idx] || 0)
  end
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "  \e[90mMerged from the in-process function tests and the `ruby main.rb`"
  puts "  subprocesses.\e[0m"
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  FileUtils.rm_rf(COVERAGE_DIR)
  exit exit_code
end
