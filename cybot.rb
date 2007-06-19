
#
# CyBot.
#
# Set the version
$version = "0.2"


# Some modules we need.
require 'thread'
require 'pluginbase'
require 'configspace/configspace'
require 'lib/logging'

# Create a log instance
$log = Logging.new

$log.puts "CyBot v#{$version} starting up..."

# =====================
# = Plugin management =
# =====================

# Root plugins. We always need these.
RootPlugins = ['plugin', 'irc', 'user', 'test']

# Provide a namespace for plugins.
module Plugins
end

# Tries to load the named plugin.
# Should reload if already loaded.
# Names are lower-case or properly cased?.
# RAISES: LoadError, PluginError.
def load_plugin(name)

  # FIXME: Have a few places to look.

  begin

    # Try to load.
    n = name.downcase
    Plugins.module_eval { load("lib/#{n}.rb") }

    # Find the class.
    if (klass = self.class.const_get(n.capitalize))

      # Initialize it.
      ins = klass.shared_instance
      $plugins[ins.name] = ins
      $log.puts "Core plugin '#{ins.name.capitalize}' loaded."

    else
      $log.puts "Error loading core plugin '#{n.capitalize}':"
      $log.puts "Couldn't locate plugin class."
    end

  rescue Exception => e
    $log.puts "Error loading core plugin '#{n.capitalize}':"
    $log.puts e.message
    $log.puts e.backtrace.join("\n")
  end

end

# Some global maps.
$commands  = {}
$hooks     = {}
$plugins   = {}

# Load global configuration.
$config = ConfigSpace.new(ARGV[0]) or return 1
$config.prefix = <<EOS
# CyBot 0.2 main configuration file. Be careful when editing this file manually,
# as it is automatically saved run-time. On-line edit is recomended.

#########    --------------------------------------------------    #########
#########    REMEMBER TO SHUT DOWN THE BOT BEFORE YOU EDIT THIS    #########
#########    --------------------------------------------------    #########
#########    This is because the bot writes the whole of this      #########
#########    file out when it is closed down.                      #########
#########    --------------------------------------------------    #########
EOS

# Save everything.
@save_all_mutex = Mutex.new
def save_all(quiet = false)
  @save_all_mutex.synchronize do
    $log.puts 'Saving plugin data...' unless quiet
    $plugins.each do |n,p|
      begin
        $log.print "      #{n}... " unless quiet
        p.save
        $log.puts "Ok" unless quiet
      rescue Exception => e
        $log.puts "Failed with error: #{e.message}" unless quiet
      end
    end
    $log.puts 'Saving global configuration...' unless quiet
    $config.save
  end
end

# Handler on ctrl-c at this point.
Signal.trap 'INT' do
  Signal.trap 'INT', 'DEFAULT'
  $log.puts 'Shutdown in progress. Press ctrl-c again to abort immediately.'
  $log.puts 'Asking IRC handlers to quit...'
  IRC::Server.quit('Ctrl-c pressed on console...')
end

# Load root plugins.
$: << File.expand_path('support')
RootPlugins.each { |name| load_plugin(name) }
$plugins.each_value do |plugin|
  plugin.on_startup if plugin.respond_to? :on_startup
end

# Set up timer to save data on regular intervals.
Thread.new do
  loop do
    sleep(60*60)
    save_all(true)
  end
end

# Done. Wait for quit.
$log.puts 'Startup complete!'
IRC::Server.wait

# Tell all plugins to save, and then save the main config.
$log.puts 'Preparing to exit...'
save_all
$log.puts 'All done, see you next time.'

