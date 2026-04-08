workers 2
threads 3

log_format :plain
log_level :debug

request_timeout 5

# preload true
# pin_worker_cores true
# fiber_scheduler true

auto_reload_config!

bind "http://0.0.0.0:4000"

rackup_file "./config.ru"

location "/heavy-io" do
  rackup_file "./config.ru", nonblocking: true
end
