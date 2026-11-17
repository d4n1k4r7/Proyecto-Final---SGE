import Config

# Carga la configuración del entorno actual (dev, test o prod).
import_config "#{config_env()}.exs"
