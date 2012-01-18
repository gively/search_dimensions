require "search_dimensions/version"

module SearchDimensions
  class Dimension
    attr_accessor :model_class, :label, :field, :param, :facet_options
    
    def initialize(model_class, params={})
      @model_class = model_class
    
      params = params.with_indifferent_access
      %w{label field param value_class facet_options}.each do |attr|
        send("#{attr}=", params[attr]) if params[attr]
      end
    end
    
    def value_class
      DimensionValue
    end
    
    def value(value)
      value_class.new(self, value)
    end
    
    def value_from_params(params)
      value(params[param])
    end
    
    def configure_search!(dsl, params)
      value_from_params(params).configure_search!(dsl)
    end    
  end
  
  module ModelExtensions
    extend ActiveSupport::Concern
    
    included do
      class << self
        attr_accessor :search_dimensions
      end
              
      @search_dimensions = {}
    end
    
    module ClassMethods    
      def search_dimension(field, *args)
        params = args.extract_options!
        klass = args.first || SearchDimensions::Dimension
        
        search_dimensions[field] = klass.new(self, params.merge(:field => field))
      end
      
      def dimension_values_from_params(params)
        search_dimensions.inject({}) do |result, (field, dimension)|
          result[field] = dimension.value_from_params(params)
          result
        end
      end
      
      def configure_search!(dsl, params)
        search_dimensions.each do |field, dimension|
          dimension.configure_search!(dsl, params)
        end
      end
    end
  end
  
  class DimensionValue
    attr_accessor :dimension, :value, :facet_count
  
    def initialize(dimension, value, facet_count=nil)
      self.dimension = dimension
      self.value = value
      self.facet_count = facet_count
    end
    
    def ancestors
      []
    end
    
    def has_value?
      @value.present?
    end
    
    def configure_search!(dsl)
      if has_value?
        dsl.with(dimension.field).equal_to(value)
      else
        dsl.facet dimension.field, (dimension.facet_options || {})
      end
    end
        
    def facet_children(search)
      facet = search.facet(dimension.field)
      return [] unless facet
      
      facet.rows.map { |row| child(row) }
    end
    
    def child(row)
      self.class.new(dimension, row.value, row.count)
    end
    
    def label
      value
    end
    
    def display?
      true
    end
  end
  
  class StateDimension < Dimension
    attr_accessor :country_code, :display_unknown_states, :display_non_fips_states
  
    def initialize(model_class, options={})
      options = options.with_indifferent_access
    
      self.country_code = options.delete(:country_code) || "US"
      self.display_unknown_states = options.delete(:display_unknown_states)
      
      self.display_non_fips_states = if options.has_key?(:display_non_fips_states)
        options.delete(:display_non_fips_states)
      else
        # By default, hide non-FIPS states only for the US
        self.country_code != "US"
      end
      
      super(model_class, options)
    end
    
    def value_class
      StateValue
    end
    
    def country
      @country ||= Decoder::Countries[country_code]
    end
  end
  
  class StateValue < DimensionValue
    def known?
      dimension.country.states.has_key?(value)
    end
    
    def fips?
      dimension.country[value].fips
    end
  
    def label
      if known?
        dimension.country[value].name
      else
        value
      end
    end
    
    def display?
      ((dimension.display_unknown_states || known?) &&
       (dimension.display_non_fips_states || fips?))
    end
  end
  
  class RatingDimension < Dimension
    def value_class
      RatingValue
    end
    
    def facet_options
      { :zeros => true, :extra => :none }.merge(super || {})
    end
  end
  
  class RatingValue < DimensionValue
    def label
      if value.nil? || value.to_s == "none"
        "No rating"
      elsif value.to_i > 0
        "\u2605" * value.to_i
      elsif value.present?
        "0 stars"
      end
    end
    
    def facet_children(search)
      super.sort_by do |row|
        val = row.value
        if val.nil? || val.to_s == "none"
          -1
        else
          val.to_i
        end
      end.reverse
    end
    
    def configure_search!(dsl)
      if value.to_s == "none"
        dsl.with(dimension.field).equal_to(nil)
      else
        super
      end
    end
  end
  
  class ExplicitlyOrderedDimension < Dimension
    def value_class
      ExplicitlyOrderedValue
    end
    
    def facet_options
      { :sort => :index }.merge(super || {})
    end
  end
  
  class ExplicitlyOrderedValue < DimensionValue
    def label
      value.sub(/^\d+:/,'')
    end
  end
  
  class HierarchicalDimension < Dimension
    def value_class
      HierarchicalValue
    end
  end
  
  class HierarchicalValue < DimensionValue
    attr_reader :leaf_value
    
    def self.values_for_path(path)
      values = []
      path_to_ancestor = []
      path.each_with_index do |ancestor, index|
        path_to_ancestor << ancestor
        components = [index] + path_to_ancestor
        values << components.join("/")
      end
      values
    end
  
    def value=(new_value)
      super
      
      if new_value
        components = new_value.split(%r{/})
        @depth = components.first.to_i
        return unless components.count > 1
        
        @leaf_value = components.last
        
        @ancestors = (1..(components.count - 2)).collect do |depth|
          self.class.new(dimension, value_path(depth - 1, components.slice(1, depth)))
        end
      end
    end
    
    def depth
      @depth || 0
    end
    
    def ancestors
      @ancestors || []
    end
    
    def components
      components = ancestors.map(&:leaf_value)
      components << leaf_value if leaf_value
      components
    end
    
    def value
      value_path(depth, components)
    end
    
    def value_path(depth, components)
      ([depth] + components).join("/")
    end
    
    def child_facet_prefix
      if has_value?
        value_path(depth + 1, components) + "/"
      else
        "0/"
      end
    end
    
    def configure_search!(dsl)
      dsl.with(dimension.field).equal_to(value) if has_value?
      
      # always facet on the field, regardless of if we have a search value for it or not
  	  dsl.facet dimension.field, (dimension.facet_options || {})
  	  
      # OMFG ugly.  We need to specify a facet prefix, but Sunspot escapes slashes.
      # But we also don't want to stomp on a solr_parameter_adjustment if it exists.
      # This might break in future Sunspot versions...
 	    adjustment = dsl.instance_variable_get("@query").instance_variable_get("@parameter_adjustment")
 	    dsl.adjust_solr_params do |params|
 	      adjustment.call(params) if adjustment
 	      
 	      # Sunspot escapes slashes in facet prefixes, so this won't work if we use its
 	      # feature.  We have to do it ourselves.
 	      # http://outoftime.lighthouseapp.com/projects/20339/tickets/187-facet-prefixes-with-slashes-are-escaped
 	      params[:"f.#{Sunspot::Setup.for(dimension.model_class).field(dimension.field).indexed_name}.facet.prefix"] = child_facet_prefix
      end
    end
  end
  
  class NTEEDimension < HierarchicalDimension
    def value_class
      NTEECategory
    end
  end
  
  class NTEECategory < HierarchicalValue
    def category
      NTEE.category(leaf_value)
    end
  
    def label
      if category
        category.name
      else
        super
      end
    end
    
    def facet_children(search)
      super.sort_by(&:label)
    end
  end
end
