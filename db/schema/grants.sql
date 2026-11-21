DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'inspector') THEN
        CREATE ROLE inspector LOGIN PASSWORD 'NetoSQL2025';
    END IF;
END;
$$;

GRANT ALL PRIVILEGES ON SCHEMA levykin_food TO inspector;
GRANT USAGE ON SCHEMA information_schema, pg_catalog, exts TO inspector;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA levykin_food TO inspector;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA levykin_food TO inspector;
GRANT EXECUTE ON FUNCTION exts.uuid_generate_v4() TO inspector;
