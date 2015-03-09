require 'erb'
require 'json'
require 'em-websocket'

module ShenmeGUI

  class << self
    attr_accessor :elements, :socket
    attr_reader :temp_stack, :this

    %w{body stack flow button radio checkbox image select textline textarea label}.each do |x|
      define_method "#{x}" do |value=nil, params={}, &block|
        params.merge!({value: value})
        el = Control.new(x.to_sym, params)
        temp_stack.last.children << el unless temp_stack.empty?
        el.parent = temp_stack.last unless temp_stack.empty?
        temp_stack << el
        instance_eval &block unless block.nil?
        temp_stack.pop
        el
      end
      private x.to_sym
    end

    def handle(msg)
      match_data = msg.match(/(.+?):(\d+)(?:->)?({.+?})?/)
      command = match_data[1].to_sym
      id = match_data[2].to_i
      data = JSON.parse(match_data[3]) unless match_data[3].nil?
      target = elements[id]
      case command
        when :sync
          data.each do |k,v|
            target.properties[k.to_sym] = v
          end
        else
          event_lambda = elements[id].events[command]
          @this = elements[id]
          result = ShenmeGUI.instance_exec(&event_lambda) if event_lambda
          @this = nil
          result

      end
      target
    end

    def app(params={}, &block)
      el = body(nil, params, &block)
      File.open('index.html', 'w'){ |f| f.write el.render }
      el
    end

  end

  @elements = []
  @temp_stack = []

  class Control
    attr_accessor :id, :type, :properties, :events, :children, :parent

    @available_events = %w{click input dblclick mouseover mouseout blur focus mousemove change}.collect(&:to_sym)
    @available_properties = {
      body: %i{style},
      button: %i{style value},
      input: %i{style value},
      textarea: %i{style value cursor},
      textline: %i{style value cursor},
      stack: %i{style},
      flow: %i{style},
      image: %i{src},
      checkbox: %i{value checked},
      label: %i{value}
    }

    def self.available_properties
      @available_properties
    end

    def sync
      data = @properties
      msg = "sync:#{@id}->#{data.to_json}"
      ::ShenmeGUI.socket.send(msg)
    end

    def add_events
      data = @events.keys
      msg = "add_event:#{@id}->#{data.to_json}"
      ::ShenmeGUI.socket.send(msg)
    end

    def initialize(type, params={})
      self.type = type
      self.properties = params
      self.id = ::ShenmeGUI.elements.size
      ::ShenmeGUI.elements << self
      self.children = []
      self.events = {}
      self.class.available_properties[type].each do |x|
        define_singleton_method(x) do
          @properties[x]
        end

        define_singleton_method("#{x}=") do |v|
          @properties[x] = v
          sync
        end
      end
    end

    def render
      lib_path = $LOADED_FEATURES.grep(/.*\/lib\/shenmegui.rb/)[0]
      template_path = lib_path.match(/(.*)\/lib/)[1] + "/templates"
      if type == :body
        static_path = lib_path.match(/(.*)\/lib/)[1] + "/static"
        style = File.open("#{static_path}/semantic-ui-custom.css", 'r'){ |f| f.read }
        style << File.open("#{static_path}/style.css", 'r'){ |f| f.read }
        script = File.open("#{static_path}/script.js", 'r'){ |f| f.read }
      end
      template = ::ERB.new File.open("#{template_path}/#{type}.erb", 'r') { |f| f.read }
      content = self.children.collect{|x| x.render}.join("\n")
      template.result(binding)
    end

    @available_events.each do |x|
      define_method("on#{x}") do |&block|
        return events[x] if block.nil?
        events[x] = lambda &block
        self
      end
    end

  end

  module Server
    def self.start!
      ws_thread = Thread.new do
        EM.run do
          EM::WebSocket.run(:host => "0.0.0.0", :port => 80) do |ws|
            ws.onopen do
              puts "WebSocket connection open"
              ShenmeGUI::elements.each { |e| e.add_events }
            end

            ws.onclose { puts "Connection closed" }

            ws.onmessage do |msg|
              puts "Recieved message: #{msg}"
              ShenmeGUI.handle msg
            end
            
            ShenmeGUI.socket = ws
          end
        end
      end

      index_path = "#{Dir.pwd}/index.html"
      `start file:///#{index_path}`

      ws_thread.join
    end

  end

end