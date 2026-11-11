// 房间公钥与签名长度在两种握手中相同；签名内容由各自协议构造，不能把登记声明换成旧门铃签名。
export async function verifySignature(room: string, message: string, signature: Uint8Array): Promise<boolean> {
  if (signature.byteLength !== 64) return false;
  try {
    const key = await crypto.subtle.importKey("raw", Buffer.from(room, "base64url"), { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify("Ed25519", key, signature, new TextEncoder().encode(message));
  } catch {
    return false;
  }
}
