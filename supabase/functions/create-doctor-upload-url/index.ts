import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const ALLOWED_EXTENSIONS = ["pdf", "png", "jpg", "jpeg", "webp"];
const ALLOWED_MIME_TYPES = [
  "application/pdf",
  "image/png",
  "image/jpeg",
  "image/webp"
];
const ALLOWED_DOC_TYPES = [
  "medical_license",
  "degree_certificate",
  "identity_proof",
  "other"
];

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json"
};

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
      console.error("Missing required server environment variables.");
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

    const userId = user.id;

    // 4. Connect with Admin Service Client for Authorization Checks
    const adminClient = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { persistSession: false }
    });

    // Check user profile
    const { data: profile, error: profileError } = await adminClient
      .from("profiles")
      .select("role")
      .eq("id", userId)
      .single();

    if (profileError || !profile) {
      return new Response(
        JSON.stringify({ error: "User profile not found. Complete basic registration first", code: "PROFILE_NOT_FOUND" }),
        { status: 403, headers: corsHeaders }
      );
    }

    if (profile.role === "admin") {
      return new Response(
        JSON.stringify({ error: "Administrators cannot register as doctor practitioners", code: "ADMIN_RESTRICTED" }),
        { status: 403, headers: corsHeaders }
      );
    }

    // 5. Parse and Validate Request Payload
    let body;
    try {
      body = await req.json();
    } catch {
      return new Response(
        JSON.stringify({ error: "Malformed JSON body", code: "INVALID_JSON" }),
        { status: 400, headers: corsHeaders }
      );
    }

    const { fileName, fileType, documentType, fileSize } = body;

    const MAX_FILE_SIZE_BYTES = 10 * 1024 * 1024; // 10 MB
    if (fileSize !== undefined && (typeof fileSize !== "number" || fileSize <= 0 || fileSize > MAX_FILE_SIZE_BYTES)) {
      return new Response(
        JSON.stringify({ error: "File size must be positive and not exceed 10 MB limit (10,485,760 bytes)", code: "FILE_TOO_LARGE" }),
        { status: 400, headers: corsHeaders }
      );
    }

    if (!fileName || typeof fileName !== "string") {
      return new Response(
        JSON.stringify({ error: "fileName is required and must be a string", code: "INVALID_FILE_NAME" }),
        { status: 400, headers: corsHeaders }
      );
    }

    if (!fileType || typeof fileType !== "string" || !ALLOWED_MIME_TYPES.includes(fileType.toLowerCase())) {
      return new Response(
        JSON.stringify({ error: `Invalid fileType. Allowed: ${ALLOWED_MIME_TYPES.join(", ")}`, code: "INVALID_MIME_TYPE" }),
        { status: 400, headers: corsHeaders }
      );
    }

    if (!documentType || typeof documentType !== "string" || !ALLOWED_DOC_TYPES.includes(documentType)) {
      return new Response(
        JSON.stringify({ error: `Invalid documentType. Allowed: ${ALLOWED_DOC_TYPES.join(", ")}`, code: "INVALID_DOCUMENT_TYPE" }),
        { status: 400, headers: corsHeaders }
      );
    }

    // Validate filename rules (length 5..255, no directory traversal, whitelist extension)
    const trimmedFileName = fileName.trim();
    if (trimmedFileName.length < 5 || trimmedFileName.length > 255) {
      return new Response(
        JSON.stringify({ error: "fileName length must be between 5 and 255 characters", code: "FILE_NAME_LENGTH" }),
        { status: 400, headers: corsHeaders }
      );
    }

    if (trimmedFileName.includes("/") || trimmedFileName.includes("\\") || trimmedFileName.includes("..")) {
      return new Response(
        JSON.stringify({ error: "fileName cannot contain path separators or traversal characters", code: "INVALID_PATH_CHARS" }),
        { status: 400, headers: corsHeaders }
      );
    }

    const parts = trimmedFileName.split(".");
    if (parts.length < 2) {
      return new Response(
        JSON.stringify({ error: "fileName must have a valid extension", code: "MISSING_EXTENSION" }),
        { status: 400, headers: corsHeaders }
      );
    }

    const ext = parts[parts.length - 1].toLowerCase();
    if (!ALLOWED_EXTENSIONS.includes(ext)) {
      return new Response(
        JSON.stringify({ error: `Extension .${ext} is not allowed. Whitelist: ${ALLOWED_EXTENSIONS.join(", ")}`, code: "INVALID_EXTENSION" }),
        { status: 400, headers: corsHeaders }
      );
    }

    // Sanitize base name (alphanumeric, underscore, hyphen)
    const baseName = parts.slice(0, -1).join(".").replace(/[^a-zA-Z0-9_\-]/g, "_");
    const sanitizedFileName = `${baseName}.${ext}`;

    // Canonical path: {userId}/{sanitizedFileName}
    const storagePath = `${userId}/${sanitizedFileName}`;

    // 6. Generate Presigned Upload URL via Supabase Storage Admin API
    const { data: uploadData, error: uploadError } = await adminClient.storage
      .from("doctor-docs")
      .createSignedUploadUrl(storagePath);

    if (uploadError || !uploadData) {
      console.error("Storage createSignedUploadUrl error:", uploadError);
      return new Response(
        JSON.stringify({ error: "Failed to create secure upload URL", code: "STORAGE_UPLOAD_URL_FAILED" }),
        { status: 500, headers: corsHeaders }
      );
    }

    // 7. Return Presigned URL Payload to Client (Zero Secrets Exposed)
    return new Response(
      JSON.stringify({
        success: true,
        data: {
          storagePath: storagePath,
          signedUrl: uploadData.signedUrl,
          token: uploadData.token,
          expiresInSeconds: 3600
        }
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : "Unknown error";
    console.error("Unhandled exception in create-doctor-upload-url:", errorMsg);
    return new Response(
      JSON.stringify({ error: "Internal server error", code: "SERVER_ERROR" }),
      { status: 500, headers: corsHeaders }
    );
  }
});
