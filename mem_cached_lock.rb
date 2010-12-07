require 'dalli'
require 'zlib'

class MemCachedLock
###########################################################################################################
#
# :Author=>"madhusoodhanan nottiyath", :email=>"nottiyath@gmail.com"
# Feel free to contact me with your comments and suggestions
#
###########################################################################################################
#
#Description:
#
#This is a memcached client wrapper which reads and writes into memcache using locks and thus resolving race conditions.
#The keys can be stored either (a) as it is or (b) as encrypted key. The keys are encrypted in crc32.
#crc32 encryption is much faster than other encryptions. Almost 2000 calls per millisecond
#
###########################################################################################################
#
#For those who are interested in how I have benchmarked the encryption performance, here is my test:
# require "mem_cached_lock"
# require 'benchmark'
# mem_cached_obj      = Dalli::Client.new('localhost:11211')
# mem_cached_lock_obj = MemCachedLock.new(mem_cached_obj)
# key                 = "some_key_you_want_to_encrypt_and_test_Its_a_good_idea_to_encrypt_long_keys"
# Benchmark.measure{1000000.times{mem_cached_lock_obj.encrypt_crc32(key)}}.total
#
###########################################################################################################
#
#usage :
# require "mem_cached_lock"
# mem_cached_obj      = Dalli::Client.new('localhost:11211')
# mem_cached_lock_obj = MemCachedLock.new(mem_cached_obj )
# mem_cached_lock_obj.lock_and_set(key,val,true,expiry,raw) - encrypts and stores the key
# mem_cached_lock_obj.lock_and_set(key,val,false,expiry,raw) - stores key without encryption
# mem_cached_lock_obj.lock_and_get(key,true) - reading values from encrypted key
# mem_cached_lock_obj.lock_and_get(key,false)- reading values from unencrypted key
#
# public methods
# mem_cached_lock_obj.add_lock(key,encrypt_flag)
# mem_cached_lock_obj.delete_lock(key,encrypt_flag)
# mem_cached_lock_obj.lock_and_get(key,encrypt_flag)
# mem_cached_lock_obj.lock_get_and_delete(key,encrypt_flag)
# mem_cached_lock_obj.lock_and_set(key,val,encrypt_flag,expiry,raw)
# mem_cached_lock_obj.lock_and_append(key,val,delim,encrypt_flag,expiry,raw)
# mem_cached_lock_obj.lock_and_remove_value(key,remove_val,delim,encrypt_flag,expiry,raw)
#
###########################################################################################################

  #MemCacheLock initializer.
  def initialize(memcached_object)
   #memcached client object is passed as a parameter
    @memcached_object = memcached_object
    #sleep time while obataining locks
    @wait_time        = 0.020 #20 milliseconds
    @max_lock_tries = 25 #number of retries for obtaining lock. maximum lock retry time is 500 ms (25 x 20ms). feel free to tweek both the values as per your needs
    @default_expiry   = 3600 #1 hour
  end

  private

  def get(key,encrypt_flag)
    (encrypt_flag) ? @memcached_object.get(encrypt_crc32(key)) : @memcached_object.get(key)
  end

  def add(key,value,encrypt_flag,expiry=@default_expiry,raw=false)
    (encrypt_flag) ? @memcached_object.add(encrypt_crc32(key),value,expiry,raw) : @memcached_object.add(key,value,expiry,raw) 
  end

  def set(key,value,encrypt_flag,expiry=@default_expiry,raw=false)
    (encrypt_flag) ? @memcached_object.set(encrypt_crc32(key),value,expiry,raw) : @memcached_object.set(key,value,expiry,raw)
  end

  def delete(key,encrypt_flag)
    (encrypt_flag) ? @memcached_object.delete(encrypt_crc32(key)) : @memcached_object.delete(key)
  end

  def encrypt_crc32(mystr)
    Zlib.crc32(mystr)
  end

  public

  #
  #Important Note!!! deleting the lock is responsibility of the caller function
  #
  def add_lock(key,encrypt_flag=false)
    lock_key = "lock:#{key}"
    #expiry should be always more than (@max_lock_tries * @wait_time) with enough buffer time for other functions to execute
    expiry = 60 #one minute - also read the comment above
    tries = 0
    lock = add(lock_key,1,encrypt_flag,expiry,false)
    while(not lock and tries < @max_lock_tries)
      sleep(@wait_time)
      tries += 1
      lock = add(lock_key,1,encrypt_flag,expiry,false)
    end
    lock
  end

  def delete_lock(key,encrypt_flag=false)
    lock_key = "lock:#{key}"
    delete(lock_key,encrypt_flag)
  end

  def lock_and_get(key,encrypt_flag=false)
    lock = add_lock(key,encrypt_flag)
    if lock
      ret_val = get(key,encrypt_flag)
      delete_lock(key,encrypt_flag) #delete the lock
    end
    ret_val || nil
  end

  def lock_get_and_delete(key,encrypt_flag=false)
    lock = add_lock(key,encrypt_flag)
    if lock
      ret_val = get(key,encrypt_flag)
      delete(key,encrypt_flag) if ret_val #delete the key
      delete_lock(key,encrypt_flag) #delete the lock
    end
    ret_val || nil
  end
  def lock_and_set(key,val,encrypt_flag=false,expiry=@default_expiry,raw=false)
    lock = add_lock(key,encrypt_flag)
    if lock
      set(key,val,encrypt_flag,expiry,raw)
      delete_lock(key,encrypt_flag) #remove the lock
      return true
    end
    nil
  end

  def lock_and_append(key,val,delim,encrypt_flag=false,expiry=@default_expiry,raw=false)
    lock = add_lock(key,encrypt_flag)
    if lock
      old_val = get(key,encrypt_flag) #this will be either nil or the actual value
      set(key,"#{old_val}#{delim}#{val}",encrypt_flag,expiry,raw)
      delete_lock(key,encrypt_flag) #remove the lock
      return true
    end
    nil
  end

  #example of  lock_and_remove_value:
  #1) remove "abc" from "xyz,1243,abc,aaa,xxx"
  #2) remove "abc" from "abc" - in this case the key also will be removed
  def lock_and_remove_value(key,remove_val,delim,encrypt_flag=false,expiry=@default_expiry,raw=false)
    lock = add_lock(key,encrypt_flag)
    if lock
      if old_val = get(key,encrypt_flag)
        new_val = old_val.split(delim)
        new_val.delete(remove_val) if remove_val
        (new_val.empty?) ? delete(key,encrypt_flag) : set(key,new_val.join(delim),encrypt_flag,expiry,raw)
      end
      delete_lock(key,encrypt_flag) #remove lock
      return true
    end
    nil
  end

end

