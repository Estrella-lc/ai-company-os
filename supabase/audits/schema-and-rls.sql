-- Read-only catalog audit. Run in Supabase SQL Editor and retain every result set.
BEGIN READ ONLY;
SELECT table_name,column_name,data_type,udt_name,is_nullable,column_default FROM information_schema.columns WHERE table_schema='public' ORDER BY table_name,ordinal_position;
SELECT c.relname AS table_name,c.relrowsecurity AS rls_enabled,c.relforcerowsecurity AS rls_forced FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' ORDER BY c.relname;
SELECT schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check FROM pg_policies WHERE schemaname='public' ORDER BY tablename,policyname;
SELECT c.relname AS table_name,k.conname,k.contype,pg_get_constraintdef(k.oid) AS definition FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' ORDER BY c.relname,k.conname;
SELECT tablename,indexname,indexdef FROM pg_indexes WHERE schemaname='public' ORDER BY tablename,indexname;
SELECT event_object_table,trigger_name,event_manipulation,action_timing,action_statement FROM information_schema.triggers WHERE trigger_schema='public' ORDER BY event_object_table,trigger_name;
SELECT table_name,grantee,privilege_type FROM information_schema.table_privileges WHERE table_schema='public' ORDER BY table_name,grantee,privilege_type;
SELECT t.typname,e.enumlabel,e.enumsortorder FROM pg_type t JOIN pg_enum e ON e.enumtypid=t.oid JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname='public' ORDER BY t.typname,e.enumsortorder;
COMMIT;
