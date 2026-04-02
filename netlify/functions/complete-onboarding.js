const FORM_ID = "69ce5d845108a8000883a763";

exports.handler = async (event) => {
  const headers = {
    "Access-Control-Allow-Origin": "*",
    "Content-Type": "application/json",
  };

  if (event.httpMethod !== "POST") {
    return { statusCode: 405, headers, body: JSON.stringify({ error: "Method not allowed" }) };
  }

  const netlifyToken = process.env.NETLIFY_API_TOKEN;
  if (!netlifyToken) {
    return { statusCode: 500, headers, body: JSON.stringify({ error: "Server configuration error" }) };
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
    // Check existing form submissions for this order ID
    const response = await fetch(
      `https://api.netlify.com/api/v1/forms/${FORM_ID}/submissions`,
      { headers: { Authorization: `Bearer ${netlifyToken}` } }
    );

    if (response.ok) {
      const submissions = await response.json();
      const existing = submissions.find(s => s.data?.orderId === orderId);
      if (existing) {
        return { statusCode: 409, headers, body: JSON.stringify({ error: "Already onboarded" }) };
      }
    }

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ success: true }),
    };
  } catch (err) {
    // If the check fails, allow submission anyway -- better to have a duplicate
    // than to block a legitimate customer
    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ success: true }),
    };
  }
};
