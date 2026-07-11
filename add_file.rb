require 'xcodeproj'

project_path = 'ios/Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'Runner' }

# Find the Runner group
runner_group = project.main_group.find_subpath('Runner', false)

# Path to the file
file_path = 'Runner/BleDiscoveryManager.swift'

# Check if file already exists in the project
existing_file = runner_group.files.find { |f| f.path == 'BleDiscoveryManager.swift' }

if existing_file.nil?
  # Add the file to the group
  file_reference = runner_group.new_file('BleDiscoveryManager.swift')
  
  # Add the file to the compile sources build phase of the target
  target.source_build_phase.add_file_reference(file_reference)
  
  # Save the project
  project.save
  puts "Added BleDiscoveryManager.swift to the Xcode project."
else
  puts "BleDiscoveryManager.swift is already in the Xcode project."
end
