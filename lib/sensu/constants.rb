module Sensu
  unless defined?(Sensu::VERSION)
    # Sensu release version.
    VERSION = "0.19.2"

    # Sensu check severities.
    SEVERITIES = %w[ok warning critical unknown]

    # Process signals that trigger a Sensu process stop.
    STOP_SIGNALS = %w[INT TERM]
    RELOAD_SIGNALS = %w[HUP]
  end
end
