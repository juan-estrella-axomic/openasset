# Fields class
#
# @author Juan Estrella
require_relative 'FieldLookupStrings.rb'
require_relative '../JsonBuilder'
class Fields
    include JsonBuilder
    # @!parse attr_accessor :alive, :cardinality, :code, :rest_code, :description, :display_order, :field_display_type
    attr_accessor :alive, :cardinality, :code, :rest_code, :description, :display_order, :field_display_type

    # @!parse attr_accessor :field_type, :id, :include_on_info, :include_on_search, :name, :protected, :built_in
    attr_accessor :field_type, :id, :include_on_info, :include_on_search, :name, :protected, :built_in, :field_lookup_strings

    # Creates a Fields object
    #
    # @param args [Hash,3 Strings, nil] Takes a Hash, 3 separate strings, or no argument
    # @return [Fields object]
    #
    # @example
    #         field = Fields.new
    #         field = Fields.new({:name => "myfield", :field_type => "image", :field_display_type => "multiLine"})
    #         field = Fields.new("myfield","image","multiLine")
    def initialize(*args)
        json_obj = {}
        len = args.length
        #This check is specific to the Fields object
        if !args.empty? && args.first.is_a?(String)
            unless len == 3 && args[0].is_a?(String) && args[1].is_a?(String) && args[2].is_a?(String)
                warn "Argument Error:\n\tExpected either\n\t1. No Arguments\n\t2. A Hash\n\t" +
                     "3. Three separate string arguments." +
                     " e.g. Fields.new(name,field_type,field_display_type) in that order." +
                     "\n\tInstead got #{args.inspect} => Creating empty Fields object."
            end
            json_obj['name']               = args[0]
            json_obj['field_type']         = args[1]
            json_obj['field_display_type'] = args[2]
        else
            json_obj = Validator.validate_argument(args.first,'Fields')
        end

        @alive = json_obj['alive']
        @cardinality = json_obj['cardinality']
        @code = json_obj['code']
        @rest_code = json_obj['rest_code']
        @description = json_obj['description']
        @display_order = json_obj['display_order']
        @field_display_type = json_obj['field_display_type']     #enumerator => multiLine, singleLine, etc
        @field_type = json_obj['field_type']                     #enumerator => project, image
        @id = json_obj['id']
        @include_on_info = json_obj['include_on_info']
        @include_on_search = json_obj['include_on_search']
        @name = json_obj['name']
        @protected = json_obj['protected']
        @built_in = json_obj['built_in']
        @field_lookup_strings = []

        if json_obj['fieldLookupStrings'].is_a?(Array) && !json_obj['fieldLookupStrings'].empty?
            @field_lookup_strings = json_obj['fieldLookupStrings'].map do |item|
                FieldLookupStrings.new(item)
            end
        end
    end
end
