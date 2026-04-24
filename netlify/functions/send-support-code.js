const nodemailer = require('nodemailer');

function json(statusCode, body) {
  return {
    statusCode,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  };
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') {
    return json(200, { ok: true });
  }

  if (event.httpMethod !== 'POST') {
    return json(405, { error: 'Method not allowed' });
  }

  const expectedToken = process.env.SUPPORT_BOT_SHARED_TOKEN;
  const authHeader = event.headers.authorization || event.headers.Authorization || '';
  const providedToken = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';

  if (!expectedToken || providedToken !== expectedToken) {
    return json(401, { error: 'Unauthorized' });
  }

  let body;
  try {
    body = JSON.parse(event.body || '{}');
  } catch {
    return json(400, { error: 'Invalid JSON body' });
  }

  const { to, code, agentId } = body;
  if (!to || !code || !agentId) {
    return json(400, { error: 'Missing required fields' });
  }

  const smtpUser = process.env.BEDROCK_SMTP_USER;
  const smtpPass = process.env.BEDROCK_SMTP_APP_PASSWORD;
  const fromAddress = process.env.BEDROCK_SUPPORT_FROM || 'no-reply@bedrockadvisorygroup.com';

  if (!smtpUser || !smtpPass) {
    return json(500, { error: 'Missing SMTP configuration' });
  }

  const transporter = nodemailer.createTransport({
    service: 'gmail',
    auth: {
      user: smtpUser,
      pass: smtpPass,
    },
  });

  const mail = {
    from: `Bedrock Advisory Group <${fromAddress}>`,
    to,
    subject: 'Your Bedrock support verification code',
    text: [
      'Your Bedrock support verification code is:',
      '',
      `${code}`,
      '',
      `Agent ID: ${agentId}`,
      '',
      'This code expires in 15 minutes.',
      'If you did not request this code, you can ignore this email.',
    ].join('\n'),
    html: `
      <div style="font-family: Arial, sans-serif; line-height: 1.5; color: #111;">
        <p>Your Bedrock support verification code is:</p>
        <p style="font-size: 28px; font-weight: 700; letter-spacing: 4px;">${String(code)}</p>
        <p><strong>Agent ID:</strong> ${String(agentId)}</p>
        <p>This code expires in 15 minutes.</p>
        <p>If you did not request this code, you can ignore this email.</p>
      </div>
    `,
  };

  try {
    const info = await transporter.sendMail(mail);
    return json(200, {
      success: true,
      messageId: info.messageId,
      accepted: info.accepted,
      rejected: info.rejected,
    });
  } catch (error) {
    return json(502, {
      error: 'Failed to send email',
      detail: error.message,
    });
  }
};
