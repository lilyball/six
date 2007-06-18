#
# Logging plugin for CyBot.
#

class Logger < PluginBase

  # We want these.
#  Channel_Instances = true

  # Some per-channel init.
  def initialize(*args)
    @brief_help = 'Records various channel activities.'
    @seen = {}
    super(*args)
  end

  # Load/save database.
  def load
    begin
      @seen = YAML.load_file(file_name('seen.db'))
    rescue
      @seen = {}
    end
  end
  def save
    open_file('seen.db', 'w') do |f|
      f.puts '# CyBot logger plugin: Seen database.'
      YAML.dump(@seen, f)
      f.puts ''
    end
  end

  # Log types.
  LogPrivmsg  = 1
  LogNotice   = 2
  LogJoin     = 3
  LogPart     = 4
  LogNick     = 5

  # Hook for PRIVMSGs to a channel the bot is in.
  def hook_privmsg_chan(irc, msg)
    l = @seen[cn = irc.channel.name] || (@seen[cn] = {})
    l[irc.from.nnick] = [Time.now, LogPrivmsg, msg]
  end

  def hook_notice_chan(irc, msg)
    l = @seen[cn = irc.channel.name] || (@seen[cn] = {})
    l[irc.from.nnick] = [Time.now, LogNotice, msg]
  end

  def hook_join_chan(irc)
    l = @seen[cn = irc.channel.name] || (@seen[cn] = {})
    l[irc.from.nnick] = [Time.now, LogJoin]
  end

  def hook_part_chan(irc)
    l = @seen[cn = irc.channel.name] || (@seen[cn] = {})
    l[irc.from.nnick] = [Time.now, LogPart]
  end

  def hook_command_serv(irc, handled, cmd, *args)
    if cmd == 'NICK'
      @seen.each_value do |c|
        c[irc.from.nnick] = [Time.now, LogNick, args[0]]
      end
    end
  end

  def chan_seen(irc, chan, nick)
    if nick
      if l = @seen[chan.name] and l = l[IRC::Address.normalize(nick)]
        irc.reply "#{nick} was last seen #{seconds_to_s((Time.now - l[0]).to_i, irc)} ago, " + case l[1]
        when LogJoin:     "joining."
        when LogPart:     "leaving."
        when LogNick:     "changing nick to #{l[2]}"
        when LogPrivmsg:  "saying: #{l[2]}"
        when LogNoting:   "noting: #{l[2]}"
        else              "doing something unknown :-p."
        end
      else
        irc.reply "I haven't seen #{nick}."
      end
    else
      irc.reply 'USAGE: seen [channel] <nick name>'
    end
  end
  help :seen, "Type 'seen <nick>' and I'll tell you when I last heard something from <nick>, and what he or she was saying or doing."

end

