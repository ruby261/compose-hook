require 'sinatra/base'
require 'json'
require 'yaml'

require_relative 'payload'

class Webhook < Sinatra::Base
  CONFIG_PATH = 'compose/docker-compose.yml'.freeze
  STAGES_PATH = '/home/deploy/webhook/stages.yml'

  set :show_exceptions, false

  def initialize
    super
    secret = ENV['WEBHOOK_JWT_SECRET']
    raise 'WEBHOOK_JWT_SECRET is not set' if secret.to_s.empty?
    @decoder = Opendax::Payload.new(secret: secret)
  end

  def update_config(service, image)
    config = YAML.load_file(CONFIG_PATH)
    return true if config["services"][service].nil?
    config["services"][service]["image"] = image
    File.open(CONFIG_PATH, 'w') {|f| f.write config.to_yaml }
    return false
  end

  before do
    content_type 'application/json'
  end

  get '/deploy/ping' do
    'pong'
  end

  get '/deploy/:token' do |token|
    decoded = @decoder.safe_decode(token)
    return answer(400, 'invalid token') unless decoded

    stages = YAML.load_file(STAGES_PATH)

    service = decoded['service']
    image = decoded['image']
    hostname = request.host
    stage_path = stages.detect { |s| s['domain'] == hostname }['path']

    return answer(400, 'service is not specified') unless service
    return answer(400, 'image is not specified') unless image
    return answer(404, 'invalid domain') unless stage_path
    return answer(400, 'invalid image') if (%r(^(([-_\w\.]){,20}(\/|:))+([-\w\.]{,20})$) =~ image) == nil

    system "docker image pull #{image}"

    unless $?.success?
      system("docker image inspect #{image} > /dev/null")
      return answer(404, 'invalid image') unless $?.success?
    end

    if $?.success?
      Dir.chdir(stage_path)

      return answer(404, 'unknown service') if update_config(service, image)
      system "docker-compose up -Vd #{service}"
    end

    return answer(500, 'could not restart container') unless $?.success?
    return answer(200, "service #{service} updated with image #{image}")
  end

  def answer(response_status, message)
    status response_status

    {
      message: message
    }.to_json
  end
end
