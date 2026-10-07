/* Site configuration.
   The publishable key is meant to be public: it only lets the browser call the
   cps_* RPC functions, which check the player's session token themselves.
   Set onlineEnabled: false to run as a purely offline (guest-only) site. */
window.CPS_CONFIG = {
  onlineEnabled: true,
  supabaseUrl: 'https://kyjzeotdtjgcxommymxw.supabase.co',
  supabaseKey: 'sb_publishable_2qvKdQ715d9W4EUjiCdJxg_Zdv_3cKr',
  siteUrl: 'https://fashe27.github.io/card-pack-opener/'
};
