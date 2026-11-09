import subprocess,concurrent.futures,json
BASE=['docker','exec','-i','ai-company-audit-pg','psql','-U','postgres','-v','ON_ERROR_STOP=1','-At']
def sql(q):
 r=subprocess.run(BASE,input=q,text=True,capture_output=True)
 if r.returncode: raise RuntimeError(r.stderr)
 return r.stdout.strip()
# One queued row, two real PostgreSQL connections competing while the first holds its lock.
sql("INSERT INTO public.messages(id,conversation_id,sender_type,content) VALUES('44444444-4444-4444-8444-444444444446','33333333-3333-4333-8333-333333333333','user','race'); SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','b8cbf27e-2391-4fb5-b061-f1488e8c3135',false); SELECT public.enqueue_chat_reply('44444444-4444-4444-8444-444444444446',gen_random_uuid());")
def claim(_): return sql("BEGIN; SET ROLE service_role; SELECT id FROM public.claim_chat_reply(); SELECT pg_sleep(0.5); COMMIT;")
with concurrent.futures.ThreadPoolExecutor(2) as p: results=list(p.map(claim,range(2)))
import re
ids=[m for r in results for m in re.findall(r'^[0-9a-f-]{36}$',r,re.M)]
assert len(ids)==1,results
assert sql("SELECT attempt_count FROM public.tasks WHERE id='"+ids[0]+"'")=='1'
# Concurrent duplicate enqueues serialize on conversation and return same task.
sql("INSERT INTO public.messages(id,conversation_id,sender_type,content) VALUES('44444444-4444-4444-8444-444444444447','33333333-3333-4333-8333-333333333333','user','enqueue race');")
def enqueue(_): return sql("SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','b8cbf27e-2391-4fb5-b061-f1488e8c3135',false); SELECT public.enqueue_chat_reply('44444444-4444-4444-8444-444444444447','55555555-5555-4555-8555-555555555556');").splitlines()[-1]
with concurrent.futures.ThreadPoolExecutor(4) as p: enqueued=list(p.map(enqueue,range(4)))
assert len(set(enqueued))==1,enqueued
print('PASS two service-role connections claimed exactly one lease; four concurrent submissions returned exactly one job')
