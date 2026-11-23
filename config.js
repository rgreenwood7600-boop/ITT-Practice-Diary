// RMSM ITT Practice Diary — Supabase connection.
//
// 1. Create a Supabase project.
// 2. Open Project Settings → API.
// 3. Paste the Project URL and the anon public key below.
//
// The anon key is meant to be in the website. Row Level Security is what
// keeps each diary private. Never put the service_role key in this file,
// in the site, or in git. That key bypasses Row Level Security.

window.ITT_CONFIG = {
  supabaseUrl: "https://YOUR_PROJECT_REF.supabase.co",
  supabaseAnonKey: "YOUR_SUPABASE_ANON_KEY"
};
