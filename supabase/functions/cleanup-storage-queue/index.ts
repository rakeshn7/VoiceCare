import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json"
};

const BATCH_SIZE = 50;
const MAX_ATTEMPTS = 5;

serve(async (req: Request) => {
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
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!supabaseUrl || !supabaseServiceKey) {
      return new Response(
        JSON.stringify({ error: "Server configuration missing", code: "CONFIG_ERROR" }),
        { status: 500, headers: corsHeaders }
      );
    }

    // Gated to service_role authorization
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.includes(supabaseServiceKey)) {
      // Also allow cron secret header if configured
      const cronSecret = Deno.env.get("CRON_SECRET");
      const clientCronSecret = req.headers.get("x-cron-secret");
      if (!cronSecret || clientCronSecret !== cronSecret) {
        return new Response(
          JSON.stringify({ error: "Unauthorized worker invocation", code: "UNAUTHORIZED_WORKER" }),
          { status: 401, headers: corsHeaders }
        );
      }
    }

    const adminClient = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { persistSession: false }
    });

    // 1. Fetch pending deletion tasks
    const { data: queueItems, error: fetchError } = await adminClient
      .from("storage_deletion_queue")
      .select("id, bucket_id, object_path, attempts")
      .in("status", ["pending", "failed"])
      .lt("attempts", MAX_ATTEMPTS)
      .order("created_at", { ascending: true })
      .limit(BATCH_SIZE);

    if (fetchError) {
      console.error("Failed to query storage_deletion_queue:", fetchError);
      return new Response(
        JSON.stringify({ error: "Queue fetch failed", details: fetchError.message }),
        { status: 500, headers: corsHeaders }
      );
    }

    if (!queueItems || queueItems.length === 0) {
      return new Response(
        JSON.stringify({ success: true, processed: 0, message: "No pending deletion tasks" }),
        { status: 200, headers: corsHeaders }
      );
    }

    let successCount = 0;
    let failureCount = 0;

    for (const item of queueItems) {
      try {
        // Mark job as processing
        await adminClient
          .from("storage_deletion_queue")
          .update({ status: "processing", attempts: item.attempts + 1 })
          .eq("id", item.id);

        // Delete physical object via Supabase Storage API
        const { error: removeError } = await adminClient.storage
          .from(item.bucket_id)
          .remove([item.object_path]);

        if (removeError) {
          // Check if object simply did not exist (404) -> treat as success
          if (removeError.message?.toLowerCase().includes("not found") || removeError.message?.includes("404")) {
            await adminClient
              .from("storage_deletion_queue")
              .update({ status: "completed", processed_at: new Date().toISOString() })
              .eq("id", item.id);
            successCount++;
          } else {
            console.error(`Error deleting storage object ${item.object_path}:`, removeError);
            const isPermanentlyFailed = (item.attempts + 1) >= MAX_ATTEMPTS;
            await adminClient
              .from("storage_deletion_queue")
              .update({
                status: isPermanentlyFailed ? "failed" : "failed",
                last_error: removeError.message || "Storage API removal error"
              })
              .eq("id", item.id);
            failureCount++;
          }
        } else {
          // Successfully removed
          await adminClient
            .from("storage_deletion_queue")
            .update({ status: "completed", processed_at: new Date().toISOString() })
            .eq("id", item.id);
          successCount++;
        }
      } catch (itemErr: unknown) {
        const itemErrMsg = itemErr instanceof Error ? itemErr.message : "Item cleanup exception";
        console.error(`Item cleanup exception for ${item.id}:`, itemErrMsg);
        await adminClient
          .from("storage_deletion_queue")
          .update({ status: "failed", last_error: itemErrMsg })
          .eq("id", item.id);
        failureCount++;
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        batchTotal: queueItems.length,
        completed: successCount,
        failed: failureCount
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : "Unhandled worker exception";
    console.error("Worker unhandled exception:", errorMsg);
    return new Response(
      JSON.stringify({ error: "Internal worker exception", details: errorMsg }),
      { status: 500, headers: corsHeaders }
    );
  }
});
