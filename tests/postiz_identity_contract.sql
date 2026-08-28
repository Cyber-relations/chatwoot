-- 固定Postiz Prisma schema (commit 81af6c9761f2c50e4741438a9e31bda222b32d2c)
-- のOrganization/User/UserOrganizationにあるscalar column・enum・index・FKを再現する。
-- production DBや資格情報は一切使わない。fixture管理はpostgres、application同期は
-- gateが別途作るtoybaco_sync_gate roleに限定する。
CREATE TYPE "Provider" AS ENUM (
  'LOCAL', 'GITHUB', 'GOOGLE', 'APPLE', 'FARCASTER', 'WALLET', 'GENERIC'
);

CREATE TYPE "Role" AS ENUM ('SUPERADMIN', 'ADMIN', 'USER');
CREATE TYPE "ShortLinkPreference" AS ENUM ('ASK', 'YES', 'NO');

CREATE TABLE "Organization" (
  id text PRIMARY KEY,
  name text NOT NULL,
  description text,
  "apiKey" text,
  "paymentId" text,
  "streakSince" timestamp(3),
  "createdAt" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" timestamp(3) NOT NULL,
  "deletedAt" timestamp(3),
  "allowTrial" boolean NOT NULL DEFAULT false,
  "isTrailing" boolean NOT NULL DEFAULT false,
  shortlink "ShortLinkPreference" NOT NULL DEFAULT 'ASK'
);

CREATE INDEX "Organization_apiKey_idx" ON "Organization"("apiKey");
CREATE INDEX "Organization_streakSince_idx" ON "Organization"("streakSince");
CREATE INDEX "Organization_paymentId_idx" ON "Organization"("paymentId");
CREATE INDEX "Organization_deletedAt_idx" ON "Organization"("deletedAt");

CREATE TABLE "User" (
  id text PRIMARY KEY,
  email text NOT NULL,
  password text,
  "providerName" "Provider" NOT NULL,
  name text,
  "lastName" text,
  "isSuperAdmin" boolean NOT NULL DEFAULT false,
  bio text,
  audience integer NOT NULL DEFAULT 0,
  "pictureId" text,
  "providerId" text,
  timezone integer NOT NULL,
  "createdAt" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" timestamp(3) NOT NULL,
  "lastReadNotifications" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "inviteId" text,
  activated boolean NOT NULL DEFAULT true,
  account text,
  "connectedAccount" boolean NOT NULL DEFAULT false,
  "lastOnline" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  ip text,
  agent text,
  "deletedAt" timestamp(3),
  "sendSuccessEmails" boolean NOT NULL DEFAULT true,
  "sendFailureEmails" boolean NOT NULL DEFAULT true,
  "sendStreakEmails" boolean NOT NULL DEFAULT true
);

CREATE UNIQUE INDEX "User_email_providerName_key" ON "User"(email, "providerName");
CREATE INDEX "User_lastReadNotifications_idx" ON "User"("lastReadNotifications");
CREATE INDEX "User_inviteId_idx" ON "User"("inviteId");
CREATE INDEX "User_account_idx" ON "User"(account);
CREATE INDEX "User_lastOnline_idx" ON "User"("lastOnline");
CREATE INDEX "User_pictureId_idx" ON "User"("pictureId");
CREATE INDEX "User_deletedAt_idx" ON "User"("deletedAt");

CREATE TABLE "UserOrganization" (
  id text PRIMARY KEY,
  "userId" text NOT NULL,
  "organizationId" text NOT NULL,
  disabled boolean NOT NULL DEFAULT false,
  role "Role" NOT NULL DEFAULT 'USER',
  "createdAt" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" timestamp(3) NOT NULL,
  CONSTRAINT "UserOrganization_userId_fkey"
    FOREIGN KEY ("userId") REFERENCES "User"(id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT "UserOrganization_organizationId_fkey"
    FOREIGN KEY ("organizationId") REFERENCES "Organization"(id) ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE UNIQUE INDEX "UserOrganization_userId_organizationId_key"
  ON "UserOrganization"("userId", "organizationId");
CREATE INDEX "UserOrganization_disabled_idx" ON "UserOrganization"(disabled);
