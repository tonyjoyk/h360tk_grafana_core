-- Sets the h360_api login password from the psql variable h360_api_password
-- (db_grants/apply.sh passes H360_API_DB_PASSWORD). The role itself comes from 0.6.5_to_0.6.6.
ALTER ROLE h360_api PASSWORD :'h360_api_password';
