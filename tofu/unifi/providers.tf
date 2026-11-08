# Authentification par variables d'environnement (clusters/<name>/cluster.env) :
#   UNIFI_API       URL du contrôleur, ex. https://192.168.2.1 (sans /api)
#   UNIFI_API_KEY   clé API UniFi OS (contrôleur >= 9.0.108)
#   UNIFI_INSECURE  true si le certificat du contrôleur n'est pas reconnu
provider "unifi" {}
