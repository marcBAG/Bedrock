const { getStore } = require("@netlify/blobs");

exports.handler = async (event) => {
  const headers = {
    "Access-Control-Allow-Origin": "*",
    "Content-Type": "application/json",
  };

  if (event.httpMethod !== "POST") {
    return { statusCode: 405, headers, body: JSON.stringify({ error: "Method not allowed" }) };
  }

  let body;
  try {
    body = JSON.parse(event.body);
  } catch {
    return { statusCode: 400, headers, body: JSON.stringify({ error: "Invalid request body" }) };
  }

  const { orderId, agreedAt } = body;
  if (!orderId || !agreedAt) {
    return { statusCode: 400, headers, body: JSON.stringify({ error: "Missing required fields" }) };
  }

  if (!orderId.startsWith("od_") && !orderId.startsWith("odp_")) {
    return { statusCode: 400, headers, body: JSON.stringify({ error: "Invalid orderId format" }) };
  }

  try {
    const store = getStore("onboarding");

    // Check if already onboarded
    const existing = await store.get(orderId);
    if (existing) {
      return { statusCode: 409, headers, body: JSON.stringify({ error: "Already onboarded" }) };
    }

    // Mark as onboarded
    await store.set(orderId, JSON.stringify({ agreedAt, completedAt: new Date().toISOString() }));

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ success: true }),
    };
  } catch (err) {
    console.error("Onboarding error:", err);
    return { statusCode: 500, headers, body: JSON.stringify({ error: "Failed to record agreement" }) };
  }
};
