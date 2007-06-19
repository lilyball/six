# 
#  logging.rb
#  Core Logging Class for Cybot
#  
#  Created by Caius Durling <dev at caius dot name> on 2007-06-18.
#  

class Logging
    
  def initialize
    @disable_time = false
  end
  
  def puts(str)
    Kernel::puts(now + str.to_s)
    @disable_time = false
  end
  
  def print(str)
    Kernel::print(now + str.to_s)
    @disable_time = !str.to_s.include?("\n")
  end
  
private
  def now
    @disable_time ? '' : Time.now.strftime('%Y-%m-%d %H:%M:%S ')
  end
end