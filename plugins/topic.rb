#
# A topic plugin to allow for multi-item topics.
# Complete rip-off of supybot.
#

class Topic < PluginBase

  # Load/save database.
  def load
    begin
      @topics = YAML.load_file(file_name('topics.db'))
    rescue
      @topics = {}
    end
  end
  def save
    open_file('topics.db', 'w') do |f|
      f.puts '# CyBot topic plugin: Topic database.'
      YAML.dump(@topics, f)
      f.puts ''
    end
  end

  def initialize
    @brief_help = 'Manipulates channel topic.'
    super
    @topics = {}
    tp = {
      :help => 'Makes the topic plugin save topic on exit and restore it on join. If not set, the current channel topic is read on join.',
      :type => Boolean
    }
    tf = {
      :help => 'Makes the topic plugin automatically follow all topic changes.',
      :type => Boolean
    }
    tcap = {
      :help => "Allows user to use the 'topic' command to change the channel topic.",
      :type => Boolean
    }
    $config.merge(
      'servers' => {
        :dir => true,
        :skel => {
          :dir => true,
          'topic-preserve' => tp,
          'topic-follow' => tf,
          'defaults' => {
            :dir => true,
            'topic' => tcap
          },
          'topic' => tcap,
          'channels' => {
            :dir => true,
            :skel => {
              :dir => true,
              'topic-preserve' => tp,
              'topic-follow' => tf,
              'defaults' => {
                :dir => true,
                'topic' => tcap
              }
            }
          },
          'users' => {
            :dir => true,
            :skel => {
              :dir => true,
              'topic' => tcap,
              'channels' => {
                :dir => true,
                :skel => {
                  :dir => true,
                  'topic' => tcap
                }
              }
            }
          }
        }
      },
      'plugins' => {
        :dir => true,
        'topic' => {
          :help => 'Settings for the topic plugin.',
          :dir => true,
          'separator' => "Topic item separator. Defaults to '|'",
          'maxlength' => {
            :help => 'The maximum length of the topic line.',
            :type => Integer
          },
          'preserve' => tp,
          'follow' => tf
        }
      }
    )
  end

  # On-join hook. Read topic, if enabled, or set our own.
  def hook_init_chan(irc)
    c = irc.channel
    t = @topics[cn = c.name] || (@topics[cn] = [nil, nil])
    if setting_cs(irc, 'topic-preserve') { $config['plugins/topic/preserve'] }
      t[1] = read_topic(c)
      topic(c, t[0])
    else
      t[1] = t[0]
      t[0] = read_topic(c)
    end
  end

  # On topic change. Read if enabled.
  def hook_topic_chan(irc, topic)
    return if !irc.from or irc.from.nick == irc.server.nick
    if setting_cs(irc, 'topic-follow') { $config['plugins/topic/follow'] }
      t = @topics[cn = irc.channel.name] || (@topics[cn] = [nil, nil])
      sep = $config['plugins/topic/separator', '|']
      t[0] = t[1] = topic.split(" #{sep} ")
    end
  end

  # Internal helper to avoid repetition.
  def topic(chan, topic)
    sep = $config['plugins/topic/separator', '|']
    chan.server.cmd('TOPIC', chan.name, topic.join(" #{sep} "))
  end

  # Split into an integer list. Raises ArgumentError.
  def int_list(data)
    raise ArgumentError unless data
    data.split.map do |e|
      raise ArgumentError if e.nil?
      Integer(e)
    end
  end

  # Check if list is a permutation of the numbers 1...n. Raises RuntimeError.
  def check_permute(list, n)
    raise ArgumentError unless list.length == n
    a = Array.new(n)
    list.each do |e|
      raise ArgumentError if e < 1 or e > n or a[e-1]
      a[e-1] = true
    end
    raise ArgumentError if a.any? { |e| e.nil? }
  end

  # Perform topic reorder.
  def reorder(chan, topics, list)
    c = topics[0]
    topics[1] = (u = c.dup)
    list.length.times { |i| c[i] = u[list[i] - 1] }
    topic(chan, c)
  end

  # Silly test command.
  def chan_list(irc, chan, line)
    stuff = common(irc, chan, line) or return
    data, t, current, undo = stuff
    irc.reply "Topic: #{current.join(" | ")}"
  end

  # Read topic from channel.
  def read_topic(chan)
    sep = $config['plugins/topic/separator', '|']
    (topic = chan.topic) ? topic.split(" #{sep} ") : []
  end

  # Common stuff.
  def common(irc, chan, line)
    if !$user.caps(irc, 'topic', 'op', 'owner').any?
      irc.reply "I'm afraid you're not allowed to do that!"
      return false
    end
    unless chan.me.op?
      irc.reply 'For now, I must be operator to manipulate the topic.'
      return false
    end
    t = @topics[chan.name] || (@topics[chan.name] = [[], []])
    current, undo = t
    line = nil if line and line.empty?
    [line, t, current, undo]
  end

  def chan_set(irc, chan, line)
    stuff = common(irc, chan, line) or return
    data, t, current, undo = stuff
    if data
      t[1], t[0] = current, (c = [data])
      topic(chan, c)
    else irc.reply 'USAGE: topic set <topic string>' end
  end
  help :set, 'Sets the channel topic to the line provided.'

  def chan_add(irc, chan, line)
    stuff = common(irc, chan, line) or return
    data, t, current, undo = stuff
    if data
      t[1] = current.dup
      current << data
      topic(chan, current)
    else irc.reply 'USAGE: topic add <topic item>' end
  end
  help :add, 'Adds the given item to the list of topics in the channel.'

  def chan_del(irc, chan, line)
    stuff = common(irc, chan, line) or return
    data, t, current, undo = stuff
    begin
      raise ArgumentError unless data
      i = Integer(data)
      if i <= (l = current.length) and i >= 1
        undo = current.dup
        current.delete_at(i - 1)
        topic(chan, current)
      else
        irc.reply "Item number is out of range. There are #{l} items in the topic."
      end
    rescue ArgumentError
      irc.reply 'USAGE: topic del <item number>'
    end
  end
  help :del, 'Deletes the item number (1-base) from the channel topic list.'

  def chan_reorder(irc, chan, line)
    stuff = common(irc, chan, line) or return
    data, t, current, undo = stuff
    begin
      l = int_list(data)
      check_permute(l, current.length)
      reorder(chan, t, l)
    rescue ArgumentError
      irc.reply 'USAGE: topic reorder <position 1> ... <position n>'
    end
  end
  help :reorder, 'Reorders the channel topic list. You must provide a permutation of the numbers 1-n (both included), where n is the number of topic items. Example: topic reorder 2 4 1 3, if there are four items.'

  def chan_swap(irc, chan, line)
    stuff = common(irc, chan, line) or return
    data, t, current, undo = stuff
    begin
      l = int_list(data)
      raise ArgumentError unless l.length == 2
      i, j = l
      l = current.length
      if i >= 1 and i <= l and j >= 1 and j <= l
        if i == j: irc.reply "That seems rather silly, doesn't it?"
        else
          undo = current.dup
          current[i-1], current[j-1] = current[j-1], current[i-1]
          topic(chan, current)
        end
      else
        irc.reply "Item numbers are out of range. There are #{l} items in the topic."
      end
    rescue ArgumentError
      irc.reply 'USAGE: topic swap <item number 1> <item number 2>'
    end
  end
  help :swap, 'Swaps the two topic items (numbered from 1) in the channel topic list.'

  def chan_shuffle(irc, chan, line)
    stuff = common(irc, chan, line) or return
    data, t, current, undo = stuff
    l = current.length
    a = (1..l).to_a
    b = []
    l.times { |i| b << a.delete_at(rand(l - i)) }
    reorder(chan, t, b)
  end
  help :shuffle, 'Randomly permutes the channel topic list.'

  def chan_undo(irc, chan, line)
    stuff = common(irc, chan, line) or return
    data, t, current, undo = stuff
    t[1], t[0] = current, undo
    topic(chan, undo)
  end
  help :undo, 'Undoes the last channel topic change (if caused by one of the topic commands).'

  def chan_restore(irc, chan, line)
    stuff = common(irc, chan, line) or return
    data, t, current, undo = stuff
    list = read_topic(chan)
    if list != current
      t[1] = list
      topic(chan, current)
    end
  end
  help :restore, 'Restores the last channel topic set with one of the topic commands.'

  def chan_read(irc, chan, line)
    stuff = common(irc, chan, line) or return
    data, t, current, undo = stuff
    list = read_topic(chan)
    t[0], t[1] = list, t[0]
    irc.reply "Ok. Found #{list.length} topic items."
  end
  help :read, 'Reads and parses the currently set channel topic line. Use this if someone else changes the topic and you want the bot to grab it.'

  def chan_replace(irc, chan, line)
    stuff = common(irc, chan, line) or return
    data, t, current, undo = stuff
    begin
      raise ArgumentError unless data
      i, txt = data.split(' ', 2)
      raise ArgumentError unless txt
      i = Integer(i)
      if i <= (l = current.length) and i >= 1
        current[i - 1] = txt
        topic(chan, current)
      else
        irc.reply "Item number is out of range. There are #{l} items in the topic."
      end
    rescue ArgumentError
      irc.reply 'USAGE: topic replace <item number> <new topic item>'
    end
  end
  help :replace, 'Replaces the given topic item (numbered from 1) in the channel topic list.'

end
