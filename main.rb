require "erb"
require "pathname"
require 'fileutils'

def env_has_key(key)
  !ENV[key].nil? && ENV[key] != '' ? ENV[key] : abort("Missing #{key}.")
end

release_notes_path = ENV['AC_RELEASE_NOTES_PATH']

# Release notes given by the user
unless release_notes_path.nil? || release_notes_path.empty?
  repository_path = env_has_key('AC_REPOSITORY_DIR')
  release_notes_path = (Pathname.new repository_path).join(Pathname.new(release_notes_path))
  output_dir  = env_has_key('AC_OUTPUT_DIR')
  output_path = File.expand_path(File.join(output_dir, 'release-notes.txt'))
  FileUtils.cp release_notes_path, "#{output_path}"
  puts "Release notes: #{release_notes_path} copied to #{output_path}"
  exit 0
end

# Release notes generated from the template
auto_generate = ENV['AC_AUTO_RELEASE_NOTES'] == 'true'
if auto_generate
  puts "Auto-generating release notes..."
  template = ENV['AC_RELEASE_NOTES_TEMPLATE']
  message = ERB.new(template, trim_mode: "%<>")
  output_dir  = env_has_key('AC_OUTPUT_DIR')
  output_path = File.expand_path(File.join(output_dir, 'release-notes.txt'))
  open(output_path, 'w') { |f|
    f.puts message.result
  } 
  exit 0
else
  puts "No release notes given. Please provide a release notes file or set AC_AUTO_RELEASE_NOTES to true."
  exit 0
end
