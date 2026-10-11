-- Local docker compose only: one database per service, like the kubemart-db
-- cluster in Kubernetes ("catalog" is created by POSTGRES_DB).
CREATE DATABASE orders;
CREATE DATABASE payments;
