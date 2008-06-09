#
# TextMate related stuff.
#

require 'async'
require 'net/http'
require 'set'

class Textmate < PluginBase

  def phrase_to_keywords(phrase)
    phrase.gsub(/\b(\w+)s\b/, '\1').downcase.split(/\W/).to_set
  end

  def parse_toc(text)
    res = []
    text.grep(%r{<li>\s*([\d.]+)\s*<a href=['"](.*?)['"]>(.*?)</a>}) do |line|
      section = $1
      url = $2
      title = $3.gsub(%r{</?\w+>}, '')
      res << {
        :title    => "#{section} #{title}",
        :link     => "http://manual.macromates.com/en/#{url}",
        :keywords => phrase_to_keywords(title)
      }
    end
    res
  end

  def cmd_doc(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: doc <search string or regex>'
    else
      Async.run(irc) do
        Net::HTTP.start('manual.macromates.com') do |http|
          re = http.get('/en/',  { 'User-Agent' => 'CyBrowser' })
          if re.code == '200'

            search_keywords = phrase_to_keywords(line)
            entries = parse_toc re.body
            matches = entries.find_all { |m| search_keywords.subset? m[:keywords] }
            if matches.empty?
              irc.reply 'No matches found.'
            else
              ranked = matches.map { |m| m.merge({ :rank => search_keywords.length.to_f / m[:keywords].length }) }
              hit = ranked.max { |a, b| a[:rank] <=> b[:rank] }
              irc.respond "\x02#{hit[:title]}\x0f #{hit[:link]}"
            end

          else
            irc.reply "Documentation site returned an error: #{re.code} #{re.message}"
          end
        end
      end
    end
  end
  help :doc, 'Searches the TextMate manual for the given string or regex.'

  def parse_faq(text)
    res = [ ]
    text.grep(%r{<a name=["'](.*?)["'][^>]*>.*?Keywords:(.*?)</span>}) do |line|
      res << {
        :link     => 'http://wiki.macromates.com/Main/FAQ#' + $1,
        :keywords => phrase_to_keywords($2)
      }
    end
    res
  end

  def cmd_faq(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: faq <search keyword(s)>'
    else
      Async.run(irc) do
        Net::HTTP.start('wiki.macromates.com') do |http|
          re = http.get('/Main/FAQ',  { 'User-Agent' => 'CyBrowser' })
          if re.code == '200'

            search_keywords = phrase_to_keywords(line)
            entries = parse_faq re.body
            matches = entries.find_all { |m| search_keywords.subset? m[:keywords] }
            if matches.empty?
              irc.reply 'No matches found.'
            else
              ranked = matches.collect { |m| m.merge({ :rank => search_keywords.length.to_f / m[:keywords].length }) }
              hit = ranked.max { |a, b| a[:rank] <=> b[:rank] }
              irc.respond hit[:link]
            end

          end
        end
      end
    end
  end
  help :faq, 'Searches the TextMate FAQ for the given keyword(s).'

  def cmd_howto(irc, line)
    if line.to_s.empty?
    	irc.reply 'USAGE: howto <search keyword(s)>'
    else
      Async.run(irc) do
      	wiki_host  = 'wiki.macromates.com'
      	wiki_path  = '/Main/HowTo/'
      	wiki_group = 'HowTo'

      	Net::HTTP.start(wiki_host) do |http|
      		re = http.get(wiki_path,  { 'User-Agent' => 'CyBrowser' })
      		if re.code == '200'
      			toc = re.body.scan(%r{<a .*\bhref=['"](http://#{wiki_host}/#{wiki_group}/(?!HomePage|RecentChanges).+)['"][^>]*>(.*?)</a>})
      			entries = toc.map do |e|
      				words = e[1].gsub(/([A-Z]+)([A-Z][a-z])/,'\1 \2').gsub(/([a-z\d])([A-Z])/,'\1 \2')
      				{	:link     => e[0],
      					:keywords => phrase_to_keywords(words)
      				}
      			end

      			search_keywords = phrase_to_keywords(line)
      			matches = entries.find_all { |m| search_keywords.subset? m[:keywords] }
      			if matches.empty?
      				irc.reply 'No matches found.'
      			else
      				ranked = matches.collect { |m| m.merge({ :rank => search_keywords.length.to_f / m[:keywords].length }) }
      				hit = ranked.max { |a, b| a[:rank] <=> b[:rank] }
      				irc.respond hit[:link]
      			end

      		else
      			irc.reply "Wiki site returned an error: #{re.code} #{re.message}"
      		end
      	end
      end
    end
  end
  help :howto, 'Searches http://wiki.macromates.com/Main/HowTo/ for the given keyword(s).'

  def cmd_ts(irc, line)
    if line.to_s.empty?
    	irc.reply 'USAGE: ts <search keyword(s)>'
    else
      Async.run(irc) do
      	wiki_host  = 'wiki.macromates.com'
      	wiki_path  = '/Troubleshooting/HomePage/'
      	wiki_group = 'Troubleshooting'

      	Net::HTTP.start(wiki_host) do |http|
      		re = http.get(wiki_path,  { 'User-Agent' => 'CyBrowser' })
      		if re.code == '200'
      			toc = re.body.scan(%r{<a .*\bhref=['"](http://#{wiki_host}/#{wiki_group}/(?!HomePage|RecentChanges).+)['"][^>]*>(.*?)</a>})
      			entries = toc.map do |e|
      				words = e[1].gsub(/([A-Z]+)([A-Z][a-z])/,'\1 \2').gsub(/([a-z\d])([A-Z])/,'\1 \2')
      				{	:link     => e[0],
      					:keywords => phrase_to_keywords(words)
      				}
      			end

      			search_keywords = phrase_to_keywords(line)
      			matches = entries.find_all { |m| search_keywords.subset? m[:keywords] }
      			if matches.empty?
      				irc.reply 'No matches found.'
      			else
      				ranked = matches.collect { |m| m.merge({ :rank => search_keywords.length.to_f / m[:keywords].length }) }
      				hit = ranked.max { |a, b| a[:rank] <=> b[:rank] }
      				irc.respond hit[:link]
      			end

      		else
      			irc.reply "Wiki site returned an error: #{re.code} #{re.message}"
      		end
      	end
      end
    end
  end
  help :ts, 'Searches http://wiki.macromates.com/Troubleshooting/HomePage/ for the given keyword(s).'

  def cmd_calc(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: calc <expression>. The expression must be in the bc language.'
    else
      Async.run(irc) do
        result = nil
        IO.popen('bc -l 2>&1', 'r+') do |f|
          f.puts line
          result = f.gets.strip
        end
        irc.reply result
      end
    end
  end
  help :calc, "Calculates the expression given and returns the answer. The expression must be in the bc language."

end

