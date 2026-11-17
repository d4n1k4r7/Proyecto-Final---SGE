import Config

# Las pruebas usan su propia carpeta para no borrar los datos reales de "data/".
# (/tmp/ ya está en el .gitignore del proyecto)
config :emergency_system, data_dir: "tmp/test_data"

config :logger, level: :warning
