/**
 * Phone number handling for the WhatsApp-style onboarding flow.
 *
 * Numbers are stored in E.164 without the leading '+': country code digits
 * followed by the subscriber digits. That form is what the server uses to
 * decide whether an incoming OTP request belongs to one of the two enrolled
 * people.
 */

export class PhoneError extends Error {
  constructor(code, message) {
    super(message ?? code);
    this.code = code;
  }
}

/**
 * @param {string} countryCode  e.g. "+62", "62", "+1"
 * @param {string} phone        e.g. "812 3456 7890", "0812-3456-7890"
 * @returns {{ countryCode: string, nationalNumber: string, phone: string }}
 */
export function normalizePhone(countryCode, phone) {
  const ccDigits = String(countryCode ?? '').replace(/\D/g, '');
  if (ccDigits.length < 1 || ccDigits.length > 4) {
    throw new PhoneError('invalid_country_code');
  }

  let digits = String(phone ?? '').replace(/\D/g, '');
  // People type their number the way they dial it locally, with a trunk 0.
  digits = digits.replace(/^0+/, '');
  if (digits.length < 4 || digits.length > 14) {
    throw new PhoneError('invalid_phone');
  }

  const full = ccDigits + digits;
  if (full.length < 7 || full.length > 15) {
    throw new PhoneError('invalid_phone');
  }

  return { countryCode: `+${ccDigits}`, nationalNumber: digits, phone: full };
}

/** Display helper: "+62 812 3456 7890" */
export function formatPhone(countryCode, nationalNumber) {
  const cc = String(countryCode ?? '').replace(/\D/g, '');
  const groups = String(nationalNumber ?? '').replace(/\D/g, '').replace(/(\d{3})(\d{4})(\d{0,4})/, '$1 $2 $3').trim();
  return `+${cc} ${groups}`.trim();
}

/** Never log a full phone number. */
export function maskPhone(phone) {
  const value = String(phone ?? '');
  if (value.length <= 6) return '•'.repeat(value.length);
  return `${value.slice(0, 4)}${'•'.repeat(Math.max(0, value.length - 7))}${value.slice(-3)}`;
}
