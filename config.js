// In. settings: which Supabase project the app talks to.
// The publishable key is meant to be public (the database rules in supabase.sql do the protecting).
// Never put a secret key (sb_secret_...) or the service_role key here. The app refuses to start with one.
window.IN_CONFIG = {
  supabaseUrl: 'https://diewnsccktlwnatpwwzx.supabase.co',
  supabaseAnonKey: 'sb_publishable_J1m54XRWBCGGwrlp54RbyQ_aGZ9taAm',

  // Set to true only after Google sign-in is switched on in Supabase.
  google: false,
};
