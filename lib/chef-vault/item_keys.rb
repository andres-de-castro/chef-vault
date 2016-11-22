# Author:: Kevin Moser <kevin.moser@nordstrom.com>
# Copyright:: Copyright 2013-15, Nordstrom, Inc.
# License:: Apache License, Version 2.0

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "chef-vault/mixins"

class ChefVault
  class ItemKeys < Chef::DataBagItem

    include ChefVault::Mixins

    def initialize(vault, name)
      super() # parentheses required to strip off parameters
      @data_bag = vault
      @raw_data["id"] = name
      @raw_data["admins"] = []
      @raw_data["clients"] = []
      @raw_data["search_query"] = []
      @raw_data["mode"] = "default"
      @cache = {} # write-back cache for keys
    end

    def [](key)
      # return options immediately
      return @raw_data[key] if %w{id admins clients search_query mode}.include?(key)
      # check if the key is in the write-back cache
      ckey = @cache[key]
      return ckey unless ckey.nil?
      # check if the key is saved in sparse mode
      spath = "#{@raw_data["id"]}_key_#{key}"
      skey = if Chef::Config[:solo_legacy_mode]
               load_solo(spath)
             else
               begin
                 Chef::DataBagItem.load(@data_bag, spath)
               rescue Net::HTTPServerException => http_error
                 nil if http_error.response.code == "404"
               end
             end
      if skey
        skey[key]
      else
        # fallback to raw data
        @raw_data[key]
      end
    end

    def include?(key)
      # check if the key is in the write-back cache
      ckey = @cache[key]
      return (ckey ? true : false) unless ckey.nil?
      # check if the key is saved in sparse mode
      spath = "#{@raw_data["id"]}_key_#{key}"
      skey = if Chef::Config[:solo_legacy_mode]
               load_solo(spath)
             else
               begin
                 Chef::DataBagItem.load(@data_bag, spath)
               rescue Net::HTTPServerException => http_error
                 nil if http_error.response.code == "404"
               end
             end
      # fallback to non-sparse mode if sparse key is not found
      @raw_data.keys.include?(key) if skey.nil?
    end

    def add(chef_key, data_bag_shared_secret)
      type = chef_key.type
      unless @raw_data.key?(type)
        raise ChefVault::Exceptions::V1Format,
              "cannot manage a v1 vault.  See UPGRADE.md for help"
      end
      @cache[chef_key.name] = ChefVault::ItemKeys.encode_key(chef_key.key, data_bag_shared_secret)
      @raw_data[type] << chef_key.name unless @raw_data[type].include?(chef_key.name)
      @raw_data[type]
    end

    def delete(chef_key)
      @cache[chef_key.name] = false
      raw_data[chef_key.type].delete(chef_key.name)
    end

    def mode(mode = nil)
      if mode
        @raw_data["mode"] = mode
      else
        @raw_data["mode"]
      end
    end

    def search_query(search_query = nil)
      if search_query
        @raw_data["search_query"] = search_query
      else
        @raw_data["search_query"]
      end
    end

    def clients
      @raw_data["clients"]
    end

    def admins
      @raw_data["admins"]
    end

    def save(item_id = @raw_data["id"])
      # create data bag if not running in solo mode
      unless Chef::Config[:solo_legacy_mode]
        begin
          Chef::DataBag.load(data_bag)
        rescue Net::HTTPServerException => http_error
          if http_error.response.code == "404"
            chef_data_bag = Chef::DataBag.new
            chef_data_bag.name data_bag
            chef_data_bag.create
          end
        end
      end

      # write cached keys to data
      @cache.each do |key, val|
        spath = "#{@raw_data["id"]}_key_#{key}"
        # delete across all modes on key deletion
        if val == false
          # sparse mode key deletion
          if Chef::Config[:solo_legacy_mode]
            delete_solo(spath)
          else
            begin
              Chef::DataBagItem.from_hash("data_bag" => data_bag, "id" => spath)
                               .destroy(data_bag, spath)
            rescue Net::HTTPServerException => http_error
              raise http_error unless http_error.response.code == "404"
            end
          end
          # default mode key deletion
          @raw_data.delete(key)
        else
          if @raw_data["mode"] == "sparse"
            # sparse mode key creation
            skey = Chef::DataBagItem.from_hash(
              "data_bag" => data_bag,
              "id" => spath, key => val
            )
            if Chef::Config[:solo_legacy_mode]
              save_solo(skey.id, skey.raw_data)
            else
              skey.save
            end
          else
            # default mode key creation
            @raw_data[key] = val
          end
        end
      end
      # save raw data
      if Chef::Config[:solo_legacy_mode]
        save_solo(item_id)
      else
        super
      end
      # clear write-back cache
      @cache = {}
    end

    def destroy
      if Chef::Config[:solo_legacy_mode]
        data_bag_path = File.join(Chef::Config[:data_bag_path],
                                  data_bag)
        data_bag_item_path = File.join(data_bag_path, @raw_data["id"])

        FileUtils.rm("#{data_bag_item_path}.json")

        nil
      else
        super(data_bag, id)
      end
    end

    def to_json(*a)
      json = super
      json.gsub(self.class.name, self.class.superclass.name)
    end

    def self.from_data_bag_item(data_bag_item)
      item = new(data_bag_item.data_bag, data_bag_item.name)
      item.raw_data = data_bag_item.raw_data
      item
    end

    def self.load(vault, name)
      begin
        data_bag_item = Chef::DataBagItem.load(vault, name)
      rescue Net::HTTPServerException => http_error
        if http_error.response.code == "404"
          raise ChefVault::Exceptions::KeysNotFound,
            "#{vault}/#{name} could not be found"
        else
          raise http_error
        end
      rescue Chef::Exceptions::ValidationFailed
        raise ChefVault::Exceptions::KeysNotFound,
          "#{vault}/#{name} could not be found"
      end

      from_data_bag_item(data_bag_item)
    end

    # @private

    def self.encode_key(key_string, data_bag_shared_secret)
      public_key = OpenSSL::PKey::RSA.new(key_string)
      Base64.encode64(public_key.public_encrypt(data_bag_shared_secret))
    end
  end
end
