import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json"
};

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SIGNED_URL_EXPIRY_SECONDS = 300; // 5 minutes

serve(async (req: Request) => {
  // 1. Handle CORS Preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed", code: "METHOD_NOT_ALLOWED" }),
      { status: 405, headers: corsHeaders }
    );
  }

  try {
    // 2. Validate Environment Variables
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!supabaseUrl || !supabaseAnonKey || !supabaseServiceKey) {
      console.error("Missing required Supabase server environment variables.");
      return new Response(
        JSON.stringify({ error: "Internal server configuration error", code: "CONFIG_ERROR" }),
        { status: 500, headers: corsHeaders }
      );
    }

    // 3. Authenticate Caller using Bearer JWT
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "Authentication required", code: "AUTH_REQUIRED" }),
        { status: 401, headers: corsHeaders }
      );
    }

    const token = authHeader.replace("Bearer ", "").trim();
    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${token}` } }
    });

    const { data: { user }, error: userError } = await userClient.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Invalid or expired session token", code: "INVALID_TOKEN" }),
        { status: 401, headers: corsHeaders }
      );
    }

    const callerId = user.id;

    // 4. Verify Administrator Role via Service Role Client
    const adminClient = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { persistSession: false }
    });

    const { data: profile, error: profileError } = await adminClient
      .from("profiles")
      .select("role")
      .eq("id", callerId)
      .single();

    if (profileError || !profile) {
      return new Response(
        JSON.stringify({ error: "User profile not found", code: "PROFILE_NOT_FOUND" }),
        { status: 403, headers: corsHeaders }
      );
    }

    if (profile.role !== "admin") {
      return new Response(
        JSON.stringify({ error: "Access denied: administrator privileges required", code: "ADMIN_REQUIRED" }),
        { status: 403, headers: corsHeaders }
      );
    }

    // 5. Parse and Validate Request Payload
    let body;
    try {
      body = await req.json();
    } catch {
      return new Response(
        JSON.stringify({ error: "Malformed JSON payload", code: "INVALID_JSON" }),
        { status: 400, headers: corsHeaders }
      );
    }

    const { doctorId, documentId } = body;

    if (!doctorId || typeof doctorId !== "string" || !UUID_REGEX.test(doctorId)) {
      return new Response(
        JSON.stringify({ error: "Valid doctorId (UUID) is required", code: "INVALID_DOCTOR_ID" }),
        { status: 400, headers: corsHeaders }
      );
    }

    if (!documentId || typeof documentId !== "string" || !UUID_REGEX.test(documentId)) {
      return new Response(
        JSON.stringify({ error: "Valid documentId (UUID) is required", code: "INVALID_DOCUMENT_ID" }),
        { status: 400, headers: corsHeaders }
      );
    }

    // 6. Verify Document Existence & Application Ownership
    // This query strictly verifies that the document belongs to the specified doctor,
    // completely preventing cross-applicant document harvesting.
    const { data: document, error: docError } = await adminClient
      .from("doctor_documents")
      .select("id, doctor_id, document_name, storage_path, document_type")
      .eq("id", documentId)
      .eq("doctor_id", doctorId)
      .single();

    if (docError || !document) {
      return new Response(
        JSON.stringify({ error: "Verification document not found for this applicant", code: "DOCUMENT_NOT_FOUND" }),
        { status: 404, headers: corsHeaders }
      );
    }

    // 7. Security Path Sanity Check
    // Storage path must strictly begin with `${doctorId}/` and cannot contain traversal characters
    const expectedPrefix = `${doctorId}/`;
    if (!document.storage_path.startsWith(expectedPrefix)) {
      return new Response(
        JSON.stringify({ error: "Corrupted storage path: path ownership mismatch", code: "PATH_OWNERSHIP_MISMATCH" }),
        { status: 403, headers: corsHeaders }
      );
    }

    if (document.storage_path.includes("..") || document.storage_path.includes("\\")) {
      return new Response(
        JSON.stringify({ error: "Invalid path characters detected", code: "INVALID_PATH" }),
        { status: 403, headers: corsHeaders }
      );
    }

    // 8. Generate Presigned Read URL (Expires in 300 seconds)
    const { data: signData, error: signError } = await adminClient.storage
      .from("doctor-docs")
      .createSignedUrl(document.storage_path, SIGNED_URL_EXPIRY_SECONDS);

    if (signError || !signData?.signedUrl) {
      console.error("Storage createSignedUrl failed:", signError);
      return new Response(
        JSON.stringify({ error: "Failed to generate secure document viewing URL", code: "SIGNING_FAILED" }),
        { status: 500, headers: corsHeaders }
      );
    }

    // 9. Return Secure Temporary Access
    return new Response(
      JSON.stringify({
        success: true,
        documentId: document.id,
        documentName: document.document_name,
        documentType: document.document_type,
        signedUrl: signData.signedUrl,
        expiresIn: SIGNED_URL_EXPIRY_SECONDS
      }),
      { status: 200, headers: corsHeaders }
    );

  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Internal server error";
    console.error("Unhandled error in create-doctor-document-view-url:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error", details: message }),
      { status: 500, headers: corsHeaders }
    );
  }
});
