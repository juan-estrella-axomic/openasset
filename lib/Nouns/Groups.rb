# Groups class
# 
# @author Juan Estrella
class Groups

    # @!parse attr_accessor :alive, :id, :name
    attr_accessor :alive, :id, :name

    # Creates a Groups object
    #
    # @param args [ Hash, 2 Strings, or nil ] Default => nil
    # @return [ Groups object]
    #
    # @example 
    #         user = Groups.new
    #         user = Groups.new("Marketing")
    #         user = Groups.new({:name=> "Marketing"})
    def initialize(*args)
        json_obj = {}

        if args.first.is_a?(String) # Assume two string args were passed
            json_obj['name'] = args.first
        else                        # Assume a Hash or nil was passed
            json_obj = Validator::validate_argument(args.first,'Groups')
        end

        @alive = json_obj['alive']
        @id = json_obj['id']
        @name = json_obj['name']
    end

    # @!visibility private
    def json
        json_data = Hash.new
        json_data[:alive] = @alive      unless @alive.nil?
        json_data[:id] = @id            unless @id.nil?
        json_data[:name] = @name        unless @name.nil?

        return json_data        
    end

end