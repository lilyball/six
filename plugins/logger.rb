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
    @corrections_for = {}
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
    if @corrections_for[irc.from.nnick] and not @corrections_for[irc.from.nnick].empty?
      if msg == 'no'
        @corrections_for[irc.from.nnick].shift
        if @corrections_for[irc.from.nnick].size == 1
          irc.reply "last try: did you mean #{@corrections_for[irc.from.nnick].first.first}?"
        elsif not @corrections_for[irc.from.nnick].empty?
          irc.reply "did you mean #{@corrections_for[irc.from.nnick].first.first}?"
        end
      elsif msg == 'yes'
        chan_seen(irc, irc.channel, @corrections_for[irc.from.nnick].first.first)
      else
        @corrections_for[irc.from.nnick] = nil unless msg =~ /^\$seen/
      end
    end
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
        corrected_nick = nil
        if @seen.has_key?("#cybot_test")
          corrections = @seen["#cybot_test"].keys.inject({}) do |hash, name|
            distance = edit_distance(nick, name).to_f
            hash[name] = distance if distance <= (nick.size + name.size.to_f) / 2.0 * 0.70
            hash
          end.sort_by { |e| e[1] }
          corrected_nick = corrections.first.first
        end
        if corrected_nick
          irc.reply "I haven't seen #{nick}, did you mean #{corrected_nick}?"
          @corrections_for[irc.from.nick] = corrections
        else
          @corrections_for[irc.from.nick] = nil
          irc.reply "I haven't seen #{nick}."
        end
      end
    else
      irc.reply 'USAGE: seen [channel] <nick name>'
    end
  end
  help :seen, "Type 'seen <nick>' and I'll tell you when I last heard something from <nick>, and what he or she was saying or doing."

end

# http://db.cs.helsinki.fi/~jaarnial/mt/archives/000074.html
def edit_distance(a, b)
  return 0 if !a || !b || a == b
  return (a.length - b.length).abs if a.length == 0 || b.length == 0
  m = [[0]]
  1.upto(a.length) { |i| m[i] = [i] }
  1.upto(b.length) { |j| m[0][j] = j }
  1.upto(a.length) do |i|
    1.upto(b.length) do |j|
      m[i][j] =
        [ m[i-1][j-1] + (a[i-1] == b[j-1] ? 0 : 1),
          m[i-1][j] + 1,
          m[i][j-1] + 1                             ].min
    end
  end
  m[a.length][b.length]
end
