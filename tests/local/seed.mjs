// Fictional local accounts so the diary can be opened without a hosted project.
// Password is for this throwaway database only.
import pg from "pg";
import { hashPassword } from "./gateway.mjs";

const password = "Portsmouth-ITT-1";
const pool = new pg.Pool({
  connectionString: process.env.ITT_ADMIN_URL || "postgres://itt_admin:itt_local_only@127.0.0.1:5432/itt_diary"
});

const section = await pool.query("select id from public.sections where name = 'Section 2'");
if (!section.rows[0]) throw new Error("Section 2 is missing. Apply supabase/schema.sql first.");

await pool.query(
  `insert into auth.users (email, raw_user_meta_data, encrypted_password)
   values ($1, $2::jsonb, $3)`,
  [
    "sam.quinn@example.test",
    JSON.stringify({
      full_name: "Sam Quinn",
      rank: "Musn",
      instrument: "Clarinet",
      section_id: section.rows[0].id
    }),
    hashPassword(password)
  ]
);

await pool.query(
  `insert into auth.users (email, raw_user_meta_data, encrypted_password)
   values ('ben.james@example.test', '{}'::jsonb, $1)`,
  [hashPassword(password)]
);

await pool.query(
  `update public.profiles
   set is_staff = true, full_name = 'Ben James', rank = ''
   where email = 'ben.james@example.test'`
);

await pool.query(
  `update public.diary_comments c
   set body = 'Tone is developing. Keep the long notes steady.',
       last_edited_name = 'Ben James',
       last_edited_at = now()
   from public.diary_months m
   join public.profiles p on p.id = m.trainee_id
   where c.diary_month_id = m.id
     and p.email = 'sam.quinn@example.test'
     and c.box_type = 'instrumental_professor'`
);

console.log("Seeded Ben James (staff) and Musn Sam Quinn (Section 2, clarinet).");
console.log("Local password for both: Portsmouth-ITT-1");
await pool.end();
