#
# Phrases plugin for CyBot.
# Ciarán Walsh 13/5/07
#
# Recognises patterns and responds with a stored phrase

class Phrases < PluginBase
  def initialize(*args)
    @brief_help = 'Repeats stored phrases'
    super(*args)
  end

  # Check a message against the phrase list
  # Returns nil, or an array of the matching pattern and response text if one is found
  def find_matching_phrase(msg)
    return nil if msg[0] == $command # Ignore commands
    @phrases.each do |(pattern, text)|
      return [pattern, text.dup] if pattern === msg
    end
    return nil
  end

  # Called for all incoming channel messages
  # Checks the message for a phrase match and replies
  def hook_privmsg_chan(irc, msg)
    pattern, text = find_matching_phrase(msg)
    return unless pattern and text

    # The hash of replacement variables that can be used in a response phrase
    vars = {}
    # Add the matches from the pattern to the replacement hash if applicable
    if pattern.is_a? Regexp
      pattern =~ msg # Why is this necessary??
      Regexp.last_match.captures.each_with_index { |cap, index| vars['$' + (index+1).to_s] = cap }
    end
    vars['me']  = irc.server.nick
    vars['you'] = irc.from.nick

    vars.each_pair { |name, val| text.gsub!('[' + name + ']', val.to_s) }
    irc.puts text#.gsub(/\[(.+?)\]/) { |match| vars.has_key?($1) ? vars[$1] : $1 }
  end

  # Checks whether the user is allowed to use this plugin
  # Informs them and returns false if not 
  def authed?(irc)
    if !$user.caps(irc, 'phrases', 'op', 'owner').any?
      irc.reply "You aren't allowed to use this command"
      return false
    end
    true
  end

  # Display a phrase for a given pattern
  # Usage: $get <pattern>
  def cmd_get(irc, phrase)
    return unless authed?(irc)
    
    if phrase.nil? or phrase.strip.empty?
      irc.reply 'USAGE: get <phrase>'
      return
    end
    pattern, text = find_matching_phrase(phrase)

    if pattern
      irc.reply "#{pattern.inspect} => #{text}"
    else
      irc.reply "No phrase matched '#{phrase}'"
    end
  end
	help :get, "Display a phrase for a given pattern.  To set phrases use 'set'"

  # Set the phrase for a pattern
  # Usage: $set <pattern> => <phrase>
  def cmd_set(irc, line)
    return unless authed?(irc)
    (pattern, text) = line.strip.split(/\s*=>\s*/, 2)

    if !pattern || !text || pattern.empty? || text.empty?
      irc.reply 'Usage: set <pattern> => <response phrase>'
      irc.reply 'Pattern can be a constant phrase or a /rege/x'
      irc.reply 'Response phrase can contain [variables]: me, you, $1+'
      return
    end

    if pattern =~ %r{\A/(.*)/([imx]*)\z}
      transform = {
        'i' => Regexp::IGNORECASE,
        'x' => Regexp::EXTENDED,
      }
      begin
        ptrn, flags = $1, $2.split(//)
        f = flags.inject(0) { |flags, letter| flags += transform[letter] if transform.has_key? letter }
        re = Regexp.new(ptrn, f)
        @phrases[re] = text
      rescue
        irc.reply "Error compiling pattern (note: only flags i & x are allowed)"
        return
      end
    else
      @phrases[pattern] = text
    end
    irc.puts 'Phrase stored'
  end
	help :set, "Set the phrase for a pattern.Usage: set <pattern> => <response phrase>. Pattern can be a constant phrase or a /rege/x./ Response phrase can contain [variables]: me, you, $1+."

  def cmd_del(irc, pattern)
    return unless authed?(irc)

    if pattern.nil? or pattern.strip.empty?
      irc.reply 'USAGE: del <pattern>'
      return
    end

    if pattern =~ %r{\A/(.*)/([imx]*)\z}
      transform = {
        'i' => Regexp::IGNORECASE,
        'x' => Regexp::EXTENDED,
      }
      begin
        ptrn, flags = $1, $2.split(//)
        f = flags.inject(0) { |flags, letter| flags += transform[letter] if transform.has_key? letter }
        pattern = Regexp.new(ptrn, f)
      rescue
        irc.reply "Error compiling pattern (note: only flags i & x are allowed)"
        return
      end
    end
    if @phrases.delete(pattern)
      irc.reply "Phrase #{pattern.inspect} deleted"
    else
      irc.reply "Phrase #{pattern.inspect} not found"
    end
  end
  
  def cmd_reload(irc, line)
    return unless authed?(irc)
    load
    irc.reply 'Phrases reloaded from disk'
  end
	help :reload, "Reloads all phrases from disk.  Make sure to save any changes you've made first."

  def cmd_save(irc, line)
    return unless authed?(irc)
    if save
      irc.reply 'Phrases saved to disk'
    else
      irc.reply "Couldn't write phrases to disk"
    end
  end
	help :save, "Save phrases to disk."

  # Load/save the phrases data
  # These seem to be called automatically at (un)load
  def load
    begin
      @phrases = YAML.load_file(file_name('phrases.yml'))
    rescue Exception => e
      @phrases = {}
    end
    @phrases = {} unless @phrases.is_a? Hash
  end
  def save
    begin
      open_file("phrases.yml", 'w') do |f|
        f.puts "# CyBot phrases plugin"
        YAML.dump(@phrases, f)
        f.puts
      end
      return true
    rescue Exception => e
      $log.puts e.message
      $log.puts e.backtrace.join("\n")
    end
    false
  end
end
