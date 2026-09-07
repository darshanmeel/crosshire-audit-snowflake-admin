-- query_id: access_grants_on_object_show
-- title: Which roles hold a read grant DIRECTLY on this object - one hop, live, SHOW only
-- domain: governance_access   tier: lite
-- rung: show - the cheapest rung that can answer a grant question at all. No IMPORTED PRIVILEGES, no admin role, and the answer is true at this second.
-- reads: SHOW GRANTS ON TABLE, result_scan(last_query_id())
-- requires: a role that can see the object - SHOW GRANTS ON an object needs a privilege on that object (or ownership of a role that holds one). No grant on the SNOWFLAKE database is needed.
-- freshness: LIVE - a grant revoked one second ago is already absent here. This is the rung that answers "did the change I just made take?"; ACCOUNT_USAGE cannot answer that for another two hours.
-- params: :object_database (default CROSSHIRE) database holding the object; :object_schema (default SILVER) schema holding it; :object_name (default ORDERS) unqualified object name. SHOW accepts no bind variables, so the three-part name is typed into the SHOW line itself - these params document exactly what to substitute there.
-- confidence: unverified
-- confidence_note: The SHOW GRANTS syntax and the RESULT_SCAN(LAST_QUERY_ID()) pipeline are documented (docs.snowflake.com/en/sql-reference/sql/show-grants), as is the rule that SHOW output identifiers are lowercase and must be double-quoted. The output column LABELS themselves appear only in doc examples and are not a stable documented contract, so this file is marked unverified: if a label differs on your version, run the SHOW on its own and read the header row.
-- empty_if: privilege_scoped
-- read_this: One row = one privilege one grantee holds DIRECTLY on this object. The two columns that matter are grantee (who) and grantee_kind (whether that is a role, a database role, or - the thing to look for - a USER). A role here is not an answer yet: it is a question for the next rung.
-- healthy: every grantee is a role you can name an owner for, grantee_kind is never USER, and with_grant_option is FALSE on everything except the object owner.
-- investigate_if: WARN when with_grant_option is TRUE on a non-owner - that grantee can hand the object to anyone without you appearing anywhere in the chain. CRITICAL when grantee_kind is USER: a privilege granted straight to a person bypasses role review entirely. False positive: a deliberately delegated data-steward role legitimately carries the grant option.
-- actions: 1) list the roles this returns and ask the object owner to name each one (free); 2) revoke any privilege granted directly to a USER and re-issue it through a role (config); 3) drop the grant option on any non-owner grantee, then re-grant without it (config).
-- next: access_who_can_read_object_proc (if any grantee is a role - this rung stops at one hop and cannot tell you who HOLDS that role), access_object_privileges_is (if you want the same one-hop answer as a joinable view rather than a SHOW result), access_who_can_read_object_au (if you also need who USED to hold the grant)
-- covers: ONE HOP, LIVE, CALLER-SCOPED. It sees exactly the grants written on this object and nothing about the role graph above them - a role named here may be held by fifty people or by nobody. It is also scoped to what your current role may see, so a grant you have no privilege to observe is silently absent rather than reported.
-- caveats: RESULT_SCAN(LAST_QUERY_ID()) reads the immediately preceding statement, so the SHOW and the SELECT must run back to back in the same session - anything in between changes the answer. SHOW GRANTS ON a view or an external table needs the matching object type in the SHOW line. The privilege filter keeps only read-conferring privileges; a grantee with OWNERSHIP appears because ownership implies the read. A role listed here may still be unable to read the object if it lacks USAGE on the database and schema - object grants alone are not sufficient.

-- Step 1 - the live grant snapshot. Substitute the three-part name; SHOW takes no bind variables.
SHOW GRANTS ON TABLE CROSSHIRE.SILVER.ORDERS;

-- Step 2 - turn that snapshot into a SELECT. Must run immediately after the SHOW above.
SELECT
  "grantee_name"                                        AS grantee,
  "granted_to"                                          AS grantee_kind,
  "privilege"                                           AS privilege,
  "granted_on"                                          AS granted_on,
  "name"                                                AS object_name,
  LOWER(TO_VARCHAR("grant_option")) = 'true'            AS with_grant_option,
  "granted_by"                                          AS granted_by,
  "created_on"                                          AS granted_at,
  CASE
    WHEN UPPER("granted_to") = 'USER'                          THEN 'CRITICAL'
    WHEN LOWER(TO_VARCHAR("grant_option")) = 'true'
         AND UPPER("privilege") <> 'OWNERSHIP'                 THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM TABLE(result_scan(last_query_id()))
WHERE UPPER("privilege") IN ('SELECT', 'OWNERSHIP', 'REFERENCES')
ORDER BY
  CASE status WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2 WHEN 'OK' THEN 3 ELSE 4 END,
  grantee;
