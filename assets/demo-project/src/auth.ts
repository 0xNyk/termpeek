import { verify } from "./crypto";
import { getRoles } from "./roles";

export interface Session {
  userId: string;
  scopes: string[];
  expiresAt: number;
}

export async function authenticate(token: string): Promise<Session | null> {
  const payload = verify(token);
  if (!payload || payload.exp * 1000 < Date.now()) {
    return null;
  }
  const scopes = await getRoles(payload.sub);
  return { userId: payload.sub, scopes, expiresAt: payload.exp * 1000 };
}
