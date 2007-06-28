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
      elsif @seen.has_key?(chan.name) and metaphone = Metaphone.create_metaphone(nick) and correction = @seen[chan.name].keys.find { |name| Metaphone.create_metaphone(name) == metaphone }
        irc.reply "I haven't seen #{nick}, perhaps you meant #{correction}?"
      else
        irc.reply "I haven't seen #{nick}."
      end
    else
      irc.reply 'USAGE: seen [channel] <nick name>'
    end
  end
  help :seen, "Type 'seen <nick>' and I'll tell you when I last heard something from <nick>, and what he or she was saying or doing."

end

class Metaphone
  TRANSFORMATIONS = [[/\A[gkp]n/  ,  'n'],   # gn, kn, or pn at the start turns into 'n'
                     [/\Ax/       ,  's'],   # x at the start turns into 's'
                     [/\Awh/      ,  'w'],   # wh at the start turns into 'w'
                     [/mb\z/      ,  'm'],   # mb at the end turns into 'm'
                     [/sch/       ,  'sk'],  # sch sounds like 'sk'
                     [/x/         ,  'ks'],
                     [/cia/       ,  'xia'], # the 'c' -cia- and -ch- sounds like 'x'
                     [/ch/        ,  'xh'],
                     [/c([iey])/  ,  's\1'], # the 'c' -ce-, -ci-, or -cy- sounds like 's'
                     [/ck/        ,  'k'],
                     [/c/         ,  'k'],
                     [/dg([eiy])/ ,  'j\1'], # the 'dg' in -dge-, -dgi-, or -dgy- sounds like 'j'
                     [/d/         ,  't'],
                     [/gh/        ,  ''],
                     [/gned/      ,  'ned'],
                     [/gn((?![aeiou])|(\z))/ ,  'n'],
                     [/g[eiy]/    ,  'j'],
                     [/ph/        ,  'f'],
                     [/[aeiou]h(?![aeoiu])/ ,  '\1'], # 'h' is silent after a vowel unless it's between vowels
                     [/q/         ,  'k'],
                     [/s(h|(ia)|(io))/ ,  'x\1'],
                     [/t((ia)|(io))/,  'x\1'],
                     [/th/        ,  '0'],
                     [/v/         ,  'f'],
                     [/w(?![aeiou])/ ,  ''],
                     [/y(?![aeiou])/ ,  ''],
                     [/z/         ,  's']
                    ]
                    
  def self.create_metaphone(aWord)
    word = aWord.to_s.downcase
    TRANSFORMATIONS.each{|transform| word.gsub!(transform.first, transform.last)}
    'a'.upto('z'){|letter| word.gsub!(letter*2, letter)}
    return (word[0].chr + word[1..word.length-1].gsub(/[aeiou]/, '')).upcase
  end
end