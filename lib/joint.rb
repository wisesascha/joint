require 'set'
require 'mime/types'
require 'wand'

module Joint
  autoload :Version, 'joint/version'

  def self.configure(model)
    model.class_inheritable_accessor :attachment_names
    model.attachment_names = Set.new
  end

  module ClassMethods
    def attachment(name)
      self.attachment_names << name

      after_save     :save_attachments
      after_save     :destroy_nil_attachments
      before_destroy :destroy_all_attachments

      field "#{name}_id".to_sym,  :type => ObjectId
      field "#{name}_name".to_sym, :type => String
      field "#{name}_size".to_sym, :type => Integer
      field "#{name}_type".to_sym, :type =>  String

      class_eval <<-EOC
        def #{name}
          @#{name} ||= AttachmentProxy.new(self, :#{name})
        end

        def #{name}?
          self.send(:#{name}_id?)
        end

        def #{name}=(file)
          if file.nil?
            nil_attachments << :#{name}
          else
            self["#{name}_id"]             = Mongo::ObjectID.new if self["#{name}_id"].nil?
            self["#{name}_size"]           = File.size(file)
            self["#{name}_type"]           = Wand.wave(file.path)
            self["#{name}_name"]           = Joint.file_name(file)
            assigned_attachments[:#{name}] = file
          end
        end
      EOC
    end
  end

  module InstanceMethods
    def grid
      @grid ||= Mongo::Grid.new(database)
    end

    private
      def assigned_attachments
        @assigned_attachments ||= {}
      end

      def nil_attachments
        @nil_attachments ||= Set.new
      end

      # IO must respond to read and rewind
      def save_attachments
        assigned_attachments.each_pair do |name, io|
          next unless io.respond_to?(:read)
          io.rewind if io.respond_to?(:rewind)
          grid.delete(send(name).id)
          grid.put(io.read, send(name).name, {
            :_id          => send(name).id,
            :content_type => send(name).type,
          })
        end
        assigned_attachments.clear
      end

      def destroy_nil_attachments
        nil_attachments.each { |name| grid.delete(send(name).id) }
        nil_attachments.clear
      end

      def destroy_all_attachments
        self.class.attachment_names.map { |name| grid.delete(send(name).id) }
      end
  end

  class AttachmentProxy
    def initialize(instance, name)
      @instance, @name = instance, name
    end

    def id
      @instance.send("#{@name}_id")
    end

    def name
      @instance.send("#{@name}_name")
    end

    def size
      @instance.send("#{@name}_size")
    end

    def type
      @instance.send("#{@name}_type")
    end

    def grid_io
      @grid_io ||= @instance.grid.get(id)
    end

    def method_missing(method, *args, &block)
      grid_io.send(method, *args, &block)
    end
  end

  def self.file_name(file)
    file.respond_to?(:original_filename) ? file.original_filename : File.basename(file.path)
  end
end
