-- query_id: access_who_can_read_object_proc
-- title: Who can read this object - transitive access, LIVE (SHOW GRANTS walker)
-- domain: governance_access   tier: standard
-- rung: procedure - an installed Snowpark walker; the rung that needs no admin and answers live
-- reads: SHOW GRANTS ON OBJECT, SHOW GRANTS OF ROLE, SHOW GRANTS OF DATABASE ROLE, RESULT_SCAN(LAST_QUERY_ID())
-- requires: only SHOW on the objects and roles in the chain (EXECUTE AS CALLER), plus CREATE PROCEDURE to install it once. No ACCOUNT_USAGE, no ACCOUNTADMIN.
-- freshness: LIVE - the answer at the instant you CALL it, with no ACCOUNT_USAGE lag
-- params: :obj (default TABLE crosshire.silver.orders) the object to seed on, passed as a CALL argument; :debug (default FALSE) print the real SHOW GRANTS column labels
-- confidence: unverified
-- confidence_note: SHOW GRANTS output column LABELS are not a documented, stable contract and drift across Snowflake versions - the getter g() tolerates the known variants, but this file is NOT doc-confirmable the way an ACCOUNT_USAGE view is. Run once with debug => TRUE to print the real labels before trusting a zero.
-- runnable: false
-- empty_if: privilege_scoped, no_activity
-- read_this: One row = a principal on an access path to the object. access_path renders the chain (role -> role -> user); status = OK is a resolved hop, status = ERROR marks a branch the caller's own role could not see.
-- healthy: every row resolves (status = OK) and the USER rows match the access list you would have written by hand.
-- investigate_if: any status <> 'OK' row - that is a branch this caller cannot see, so the answer is a LOWER BOUND on who can read the object, not the whole truth. Re-run as a role that can see it before you conclude anything.
-- actions: 1) re-run the blind branches as a role with SHOW on them, so the closure is complete (free); 2) revoke the USAGE edge that carries an unexpected principal (config); 3) if the walk is too deep to review, flatten the role design so the graph is one hop deep (config).
-- next: access_who_can_read_object_au (if you need HISTORY - who USED to have access - or cannot install a procedure)
-- covers: FULL transitive closure, LIVE, from where the caller stands. Under EXECUTE AS CALLER it is complete only up to the caller's own visibility - unreadable rows are MARKED rather than hidden. This is the rung INFORMATION_SCHEMA cannot reach (no role graph) and that does not need admin - use it first.
-- caveats: SNAPSHOT only - no deleted_on history, which is the one thing the ACCOUNT_USAGE rung does that this cannot. Depth-capped at 15; cycles and SYSTEM$ pseudo-roles guarded. This file is a CREATE PROCEDURE install script plus a usage block, NOT a plain SELECT - hence runnable: false. Read the result with RESULT_SCAN(LAST_QUERY_ID()) and pin the id immediately (it moves), or materialize into a TEMP TABLE.

-- =====================================================================
-- Install once. Grant USAGE on the procedure to the roles that run it.
-- =====================================================================
CREATE OR REPLACE PROCEDURE object_access(obj STRING, debug BOOLEAN DEFAULT FALSE)
  RETURNS TABLE (
      seed_kind STRING, seed STRING, lvl NUMBER,
      principal STRING, principal_type STRING, privilege STRING,
      granted_on STRING, object_name STRING,
      direction STRING, access_path STRING, status STRING, detail STRING )
  LANGUAGE PYTHON RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python')
  HANDLER = 'run' EXECUTE AS CALLER
AS $$
COLS = ["SEED_KIND","SEED","LVL","PRINCIPAL","PRINCIPAL_TYPE","PRIVILEGE",
        "GRANTED_ON","OBJECT_NAME","DIRECTION","ACCESS_PATH","STATUS","DETAIL"]
_CTX = {"seed_kind": "OBJECT", "seed": ""}

# --- tolerate SHOW GRANTS column-name drift ---
def g(d, *keys):
    for k in keys:
        if d.get(k) is not None:
            return d[k]
    return None
def grantee(d): return g(d, "grantee_name", "grantee")
def gtype(d):   return g(d, "granted_to", "granted_to_type", "grantee_type")

def is_system(name):
    return bool(name) and name.upper().startswith("SYSTEM$")
def is_db_type(t):
    return (t or "").upper().replace("_", " ") == "DATABASE ROLE"

def obj_db(obj):
    ident = obj.split()[-1]                 # 'TABLE crosshire.silver.orders' -> ident
    return ident.split(".")[0].strip('"')
def dbrole_ref(role, db):
    if "." in role:
        d, r = role.split(".", 1)
        return f'"{d}"."{r}"'
    return f'"{db}"."{role}"'

def row(principal, principal_type, privilege, granted_on, object_name,
        direction, access_path, status, detail=""):
    lvl = 0 if direction in ("error", "meta") else len(access_path.split(" -> "))
    return (_CTX["seed_kind"], _CTX["seed"], lvl,
            principal, principal_type, privilege, granted_on, object_name,
            direction, access_path, status, detail)

def _show(session, cmd, out):
    try:
        return [r.as_dict() for r in session.sql(cmd).collect()], None
    except Exception as e:                   # caller could not read this branch
        out.append(row("[UNREADABLE]", "", "", "", "",
                       "error", cmd, "ERROR", str(e)[:200]))
        return [], str(e)

def climb(session, seed, role, is_db, priv, gon, obj, chain, out, depth=0, maxd=15):
    if depth > maxd:
        return                               # depth backstop
    cmd = (f'SHOW GRANTS OF DATABASE ROLE {dbrole_ref(role, obj_db(obj))}' if is_db
           else f'SHOW GRANTS OF ROLE "{role}"')
    rows, err = _show(session, cmd, out)
    for r in rows:
        who, wtyp = grantee(r), gtype(r)
        if not who or who in chain or is_system(who):
            continue                         # cycle + pseudo-role guard
        new_chain = [who] + chain
        out.append(row(principal=who, principal_type=wtyp, privilege=priv,
                       granted_on=gon, object_name=obj, direction="inherited",
                       access_path=" -> ".join(new_chain), status="OK"))
        if wtyp == "ROLE":
            climb(session, seed, who, False, priv, gon, obj, new_chain, out, depth+1)
        elif is_db_type(wtyp):
            climb(session, seed, who, True,  priv, gon, obj, new_chain, out, depth+1)
        # USER is terminal — no recursion

def run(session, obj, debug=False):
    seed = obj.strip()
    _CTX["seed_kind"], _CTX["seed"] = "OBJECT", seed
    out = []
    rows, err = _show(session, f"SHOW GRANTS ON {seed}", out)   # the one seed hop
    for r in rows:
        who, wtyp = grantee(r), gtype(r)
        priv, gon = g(r, "privilege"), g(r, "granted_on")
        if not who or is_system(who):
            continue
        out.append(row(principal=who, principal_type=wtyp, privilege=priv,
                       granted_on=gon, object_name=seed, direction="direct",
                       access_path=who, status="OK"))
        if wtyp == "ROLE":
            climb(session, seed, who, False, priv, gon, seed, [who], out)
        elif is_db_type(wtyp):
            climb(session, seed, who, True,  priv, gon, seed, [who], out)
    if debug and rows:                        # emit the real column labels once
        out.append(row("(columns)", "INFO", "", "", seed, "meta",
                       " | ".join(sorted(rows[0].keys())), "OK",
                       "SHOW GRANTS column labels on this account"))
    return session.create_dataframe(out, schema=COLS)
$$;

-- =====================================================================
-- Call it, then read the result. LAST_QUERY_ID() always names the
-- PREVIOUS statement, so pin it the instant the CALL returns.
-- =====================================================================
CALL object_access('TABLE crosshire.silver.orders');
SET qid = LAST_QUERY_ID();          -- grab the CALL's id immediately

-- everyone who can read it, and the path in:
SELECT lvl, principal, principal_type, privilege, access_path
FROM TABLE(RESULT_SCAN($qid))
WHERE status = 'OK'
ORDER BY lvl, principal;

-- just the humans:
SELECT lvl, principal, access_path
FROM TABLE(RESULT_SCAN($qid))
WHERE principal_type = 'USER'
ORDER BY lvl;

-- the blind spots (branches this caller could not read):
SELECT status, detail, access_path
FROM TABLE(RESULT_SCAN($qid))
WHERE status <> 'OK';

-- --- Or materialize once and forget query-ids entirely ---
CALL object_access('TABLE crosshire.silver.orders');
CREATE OR REPLACE TEMP TABLE access_map AS
  SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT principal_type, COUNT(DISTINCT principal) AS principals
FROM access_map WHERE status = 'OK'
GROUP BY principal_type;
