import nodemailer from 'nodemailer';

/**
 * Configure Nodemailer transport.
 * Supports Gmail (via Google App Password) or custom SMTP server.
 */
export function createMailer(config = {}) {
  const host = process.env.SMTP_HOST || config.smtpHost || 'smtp.gmail.com';
  const port = Number.parseInt(process.env.SMTP_PORT || config.smtpPort || '465', 10);
  const secure = process.env.SMTP_SECURE ? process.env.SMTP_SECURE === 'true' : port === 465;
  const user = process.env.GMAIL_USER || process.env.SMTP_USER || config.smtpUser;
  const pass = process.env.GMAIL_APP_PASSWORD || process.env.SMTP_PASS || config.smtpPass;
  const from =
    process.env.SMTP_FROM ||
    process.env.MAIL_FROM ||
    config.smtpFrom ||
    (user ? `"Friend Chat" <${user}>` : '"Friend Chat" <noreply@friendchat.local>');

  let transporter = null;
  if (user && pass) {
    transporter = nodemailer.createTransport({
      host,
      port,
      secure,
      auth: { user, pass },
      tls: {
        rejectUnauthorized: process.env.NODE_ENV === 'production',
      },
    });
  }

  return {
    isConfigured: Boolean(transporter),

    async sendOtp({ toEmail, code, phone, expiresInMinutes = 10 }) {
      const subject = `Your Friend Chat Verification Code: ${code}`;
      const text = `Your Friend Chat 2-Step Verification code is: ${code}\n\nValid for ${expiresInMinutes} minutes for phone ${phone}. Do not share this code with anyone.`;

      const html = `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Friend Chat Verification</title>
</head>
<body style="margin: 0; padding: 0; background-color: #0b141a; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; color: #e9edef;">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color: #0b141a; padding: 40px 10px;">
    <tr>
      <td align="center">
        <table role="presentation" width="100%" style="max-width: 480px; background-color: #111b21; border-radius: 16px; border: 1px solid #222e35; overflow: hidden; box-shadow: 0 8px 24px rgba(0,0,0,0.4);">
          <!-- Header -->
          <tr>
            <td style="padding: 32px 32px 20px 32px; text-align: center; background: linear-gradient(180deg, #1f2c34 0%, #111b21 100%); border-bottom: 1px solid #222e35;">
              <div style="display: inline-block; width: 54px; height: 54px; line-height: 54px; border-radius: 14px; background: #00a884; color: #ffffff; font-size: 28px; font-weight: bold; margin-bottom: 12px; text-align: center;">
                💬
              </div>
              <h1 style="margin: 0; font-size: 22px; font-weight: 700; color: #e9edef; letter-spacing: -0.5px;">Friend Chat</h1>
              <p style="margin: 6px 0 0 0; font-size: 13px; color: #8696a0;">Secure Self-Hosted Cloud Messaging</p>
            </td>
          </tr>

          <!-- Body -->
          <tr>
            <td style="padding: 32px;">
              <h2 style="margin: 0 0 12px 0; font-size: 18px; font-weight: 600; color: #e9edef;">Verification Code</h2>
              <p style="margin: 0 0 24px 0; font-size: 14px; line-height: 1.6; color: #aebac1;">
                Use the one-time code below to verify your Gmail address and complete your Two-Step Verification for account:
                <strong style="color: #00a884; display: block; margin-top: 4px; font-size: 15px;">${phone}</strong>
              </p>

              <!-- Code Box -->
              <div style="background-color: #1f2c34; border: 1px dashed #00a884; border-radius: 12px; padding: 20px; text-align: center; margin: 24px 0;">
                <span style="font-family: 'Courier New', Courier, monospace; font-size: 36px; font-weight: 800; letter-spacing: 10px; color: #25d366; display: inline-block; padding-left: 10px;">
                  ${code}
                </span>
                <div style="font-size: 12px; color: #8696a0; margin-top: 8px;">
                  Expires in ${expiresInMinutes} minutes &bull; Single use only
                </div>
              </div>

              <!-- Security Warning -->
              <div style="background-color: #182229; border-left: 4px solid #f15c6d; border-radius: 6px; padding: 12px 16px; margin: 24px 0 12px 0;">
                <p style="margin: 0; font-size: 13px; line-height: 1.5; color: #e9edef;">
                  <strong style="color: #f15c6d;">Security Warning:</strong> Never share this code with anyone. Friend Chat will never ask for your code outside the official application.
                </p>
              </div>

              <p style="margin: 20px 0 0 0; font-size: 12px; line-height: 1.5; color: #8696a0;">
                If you did not initiate this request, someone may have entered your phone number by mistake. You can safely ignore this email.
              </p>
            </td>
          </tr>

          <!-- Footer -->
          <tr>
            <td style="padding: 20px 32px; background-color: #0c1317; text-align: center; border-top: 1px solid #1f2c34;">
              <p style="margin: 0; font-size: 11px; color: #667781;">
                &copy; Friend Chat &bull; 24/7 Cloud Ready &bull; Zero Manual Seeding
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
      `;

      if (transporter) {
        try {
          const info = await transporter.sendMail({
            from,
            to: toEmail,
            subject,
            text,
            html,
          });
          console.log(`[friend-chat mailer] OTP sent successfully to ${toEmail} (msgId: ${info.messageId})`);
          return { ok: true, sent: true, messageId: info.messageId };
        } catch (err) {
          console.error(`[friend-chat mailer] Failed to send email to ${toEmail}: ${err.message}`);
          // Don't crash server if SMTP fails; log clearly
          return { ok: false, sent: false, error: err.message };
        }
      } else {
        console.log(`[friend-chat mailer] (Dev/No-SMTP mode) OTP code for ${toEmail} (${phone}): ${code}`);
        return { ok: true, sent: false, simulated: true };
      }
    },
  };
}
