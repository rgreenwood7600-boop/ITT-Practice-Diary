# Set up the ITT Practice Diary

The site is a static page. Supabase holds the accounts and the diaries. Row Level Security is what keeps a trainee inside their own diary. The anon key in `config.js` is public by design. The service role key bypasses every rule: do not put it in `config.js`, in the site, or in git.

## 1. Create the Supabase project

1. Create a project at [supabase.com](https://supabase.com).
2. Open **Project Settings → API**.
3. Copy the **Project URL** and the **anon public** key into `config.js`:

```js
window.ITT_CONFIG = {
  supabaseUrl: "https://YOUR_PROJECT_REF.supabase.co",
  supabaseAnonKey: "YOUR_SUPABASE_ANON_KEY"
};
```

Leave the service role key in the Supabase dashboard.

## 2. Run the database script

1. Open **SQL Editor → New query**.
2. Paste the whole of `supabase/schema.sql`.
3. Run it. It is safe to run again: it refreshes functions, triggers and policies, and it does not delete diaries.

The script creates:

- `sections`, starting with Section 1, Section 2 and Section 3
- `profiles`, one row per account
- `diary_months` and `diary_comments`, five boxes per month
- a trigger so registering a trainee opens the current month (Europe/London)
- policies so a trainee can read their own diary and write only the Trainee box, and any staff member can write the four staff boxes

Months roll over at midnight in Portsmouth, not at midnight UTC.

## 3. Authentication settings

1. **Authentication → Sign In / Providers → Email**: leave Email enabled.
2. **Authentication → Sign In / Providers → Email → Confirm email**: turn this **off** so a trainee can open the diary as soon as they register. If you leave it on, the page asks them to confirm the email before logging in. The diary row is still created at registration.
3. **Authentication → URL Configuration**
   - Site URL: `https://<github-user>.github.io/ITT-Practice-Diary/`
   - Add the same address under Redirect URLs.
4. If the dashboard has a minimum password length, set it to 8. The page already refuses shorter passwords.

## 4. Create the shared staff login

There is one staff login, shared by the ITT staff. The page asks for a username and a password. It does not ask for an email. The username `ITTStaff` (any capitalisation) is sent to Supabase as this address:

`ittstaff@staff.itt-diary.invalid`

That address is only an internal login. The `.invalid` domain cannot receive mail. Do not put the password in the website or in git.

Staff cannot register through the page. The register form always creates a trainee. `is_staff` can be changed from the SQL editor (where there is no user JWT). The page cannot change it.

1. **Authentication → Users → Add user**.
2. Email: `ittstaff@staff.itt-diary.invalid`. Choose the shared password. Turn on **Auto Confirm User**.
3. Run this in the SQL editor:

```sql
update public.profiles
set is_staff = true,
    full_name = 'ITT Staff',
    username = 'ittstaff',
    rank = ''
where email = 'ittstaff@staff.itt-diary.invalid';
```

`rank` can stay blank. Comments are stamped with the profile name, so they read "Last edited by ITT Staff". Until that name is set, the page shows "Staff".

Run `supabase/migrations/002_usernames.sql` in the SQL editor before using this version of the page. It adds the username column, keeps usernames unique, and adds the staff password reset. It is safe to run more than once.

Trainees choose a username of 3 to 30 letters and numbers, starting with a letter. The page stores it in lower case and signs them in as `<username>@trainee.itt-diary.invalid`. That address is never shown and cannot receive mail. `ittstaff` is reserved.

On a trainee's diary, staff can set a new password. That calls `set_trainee_password`, which checks the caller is staff and then writes a bcrypt password onto the trainee's login. The service role key is not used.

Anyone who signs in with the username `ITTStaff` can write in any of the four staff boxes.

### Change the staff password

Open **Authentication → Users**, select `ittstaff@staff.itt-diary.invalid`, and set the new password on that user. Do not send a recovery email. This address cannot receive mail, so a reset link would never arrive. If the dashboard button only offers to email a link, set the password from the user page itself (the password field on the user) rather than by email.

To take staff status away later:

```sql
update public.profiles
set is_staff = false
where email = 'ittstaff@staff.itt-diary.invalid';
```

## 5. Publish the site

1. In the GitHub repository, open **Settings → Pages → Build and deployment**.
2. Set **Source** to **GitHub Actions**.
3. Push `main`, or run the **Deploy GitHub Pages** workflow with **Run workflow**. The workflow also runs on every push to `main`.

The published site is the HTML, CSS, JavaScript, fonts and `config.js` only. The SQL and the tests are not uploaded.

Open the Pages address. Register a trainee (full name, rank, section, instrument, email, password). Log in with the staff username `ITTStaff`, open that diary, and write in a staff box.

## 6. Day to day

- Trainees register with a username, not an email address. They can change their own name, rank, section and instrument. They can read every box on their own diary and write only the Trainee box. Staff can set a new password for them from the diary page.
- Staff sign in with **Staff log in**, using the username `ITTStaff` and the shared password. Filter the list by section or search by name, open a month, edit the trainee's details, or delete the trainee. Deleting asks for confirmation, then removes the login and every month of that diary.
- **Download PDF** saves one A4 month on the computer. It is produced in the browser. Nothing is sent to a second server, and there is no analytics.
- Sections are edited from the staff page. A section that still has trainees cannot be removed.

The diary does not ask for, store, or print a service number.

## 7. Optional: check the rules on a local database

`tests/run-rls.sh` creates a throwaway database, applies `supabase/schema.sql` twice, and checks the policies: a trainee cannot read or write another diary or a staff box, cannot grant themselves staff status, and staff can read, write the staff boxes, edit details and delete a trainee. It needs a local PostgreSQL server:

```bash
bash tests/run-rls.sh
```

`tests/local/up.sh` is a separate stand-in for trying the page before a Supabase project exists. It is not the production backend and it is not deployed.
