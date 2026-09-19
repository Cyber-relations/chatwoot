(() => {
  "use strict";
  const root = document.getElementById("handoff");
  if (!root) return;
  const uuid =
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  const secretPattern = /^[0-9a-f]{64}$/;
  const providerLabels = {
    line: "LINE公式",
    gmail: "Google",
    microsoft: "Microsoft",
  };
  const $ = (id) => document.getElementById(id);
  const controllers = new Set();
  const timers = new Set();
  let closed = false;
  let busy = false;
  const message = (value) => {
    $("status").textContent = value;
  };
  function error(value = "") {
    $("error").textContent = value;
    $("error").hidden = !value;
  }
  function later(fn, delay) {
    const timer = setTimeout(() => {
      timers.delete(timer);
      if (!closed) fn();
    }, delay);
    timers.add(timer);
  }
  async function request(path, body, timeout = 12000) {
    const controller = new AbortController();
    controllers.add(controller);
    const timer = setTimeout(() => controller.abort(), timeout);
    try {
      const response = await fetch(path, {
        method: body === undefined ? "GET" : "POST",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: {
          Accept: "application/json",
          ...(body === undefined ? {} : { "Content-Type": "application/json" }),
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: controller.signal,
      });
      const text = await response.text();
      if (closed) throw new Error("closed");
      let data = null;
      if (text.length <= 32768) {
        try {
          data = JSON.parse(text);
        } catch {}
      }
      if (!response.ok) {
        const failure = new Error(
          data?.error ||
            (response.status === 401
              ? "ログインし直して、この画面を開いてください。"
              : "設定を開始できません。依頼内容をご確認ください。"),
        );
        failure.status = response.status;
        failure.data = data;
        throw failure;
      }
      if (!data || typeof data !== "object" || Array.isArray(data))
        throw new Error("invalid receipt");
      return data;
    } finally {
      clearTimeout(timer);
      controllers.delete(controller);
    }
  }
  async function action(fn) {
    if (closed || busy) return;
    busy = true;
    root.setAttribute("aria-busy", "true");
    error();
    const disabled = [...root.querySelectorAll("button")].map((button) => [
      button,
      button.disabled,
    ]);
    disabled.forEach(([button]) => {
      button.disabled = true;
    });
    try {
      await fn();
    } catch (failure) {
      if (!closed)
        error(
          failure.status
            ? failure.message
            : "通信を確認して、もう一度お試しください。",
        );
    } finally {
      busy = false;
      root.removeAttribute("aria-busy");
      disabled.forEach(([button, wasDisabled]) => {
        button.disabled = wasDisabled;
      });
    }
  }
  function copy(button, input) {
    button.addEventListener("click", () =>
      action(async () => {
        try {
          await navigator.clipboard.writeText(input.value);
          message("コピーしました。");
        } catch {
          input.focus();
          input.select();
          message("表示されたURLをコピーしてください。");
        }
      }),
    );
  }
  function validState(value, states) {
    if (
      typeof value.provider !== "string" ||
      !Object.prototype.hasOwnProperty.call(providerLabels, value.provider) ||
      !states.includes(value.state) ||
      !Number.isFinite(Date.parse(value.expires_at))
    )
      throw new Error("invalid receipt");
    return value;
  }
  function scrub() {
    root.querySelectorAll("input").forEach((input) => {
      input.value = "";
    });
  }
  window.addEventListener("pagehide", () => {
    closed = true;
    controllers.forEach((controller) => controller.abort());
    timers.forEach(clearTimeout);
    scrub();
  });
  window.addEventListener("pageshow", (event) => {
    if (event.persisted) window.location.reload();
  });

  function owner() {
    const account = root.dataset.accountId;
    const provider = root.dataset.provider || "line";
    const inboxId = root.dataset.inboxId || "";
    const canCreate = root.dataset.createAvailable !== "false";
    if (
      !Object.prototype.hasOwnProperty.call(providerLabels, provider) ||
      (inboxId && !/^[1-9][0-9]{0,15}$/.test(inboxId))
    )
      return error("接続先を確認できません。");
    if (!/^[1-9][0-9]{0,15}$/.test(account))
      return error("店舗を確認できません。");
    const params = new URLSearchParams(window.location.search);
    let id = params.get("id");
    if (id && !uuid.test(id)) return error("依頼を確認できません。");
    let requestId = params.get("request");
    if (!uuid.test(requestId || "")) requestId = crypto.randomUUID();
    let pendingBody = null;
    let current = null;
    let polls = 0;
    const endpoint = `/toybaco/connections/handoffs`;
    const scoped = (path) => `${path}?account_id=${account}`;
    function keepUrl() {
      const next = new URL(window.location.href);
      next.search = new URLSearchParams({
        account_id: account,
        ...(provider !== "line" ? { provider } : {}),
        ...(inboxId ? { inbox_id: inboxId } : {}),
        ...(id ? { id } : { request: requestId }),
      });
      next.hash = "";
      history.replaceState(null, "", next.pathname + next.search);
    }
    function render(value) {
      validState(value, [
        "issued",
        "claimed",
        "completed",
        "expired",
        "revoked",
      ]);
      if (
        !uuid.test(value.id) ||
        (id && value.id !== id) ||
        value.provider !== provider
      )
        throw new Error("invalid request");
      let link = "";
      if (value.url) {
        const url = new URL(value.url);
        if (
          url.origin !== location.origin ||
          url.username ||
          url.password ||
          url.search ||
          url.pathname !== `/toybaco/connections/help/${value.id}` ||
          !secretPattern.test(url.hash.slice(1))
        )
          throw new Error("invalid link");
        link = url.href;
      }
      current = value;
      id = value.id;
      keepUrl();
      const terminal = ["completed", "expired", "revoked"].includes(
        value.state,
      );
      $("request-form").hidden =
        !canCreate || !["expired", "revoked"].includes(value.state);
      $("request-result").hidden = false;
      $("request-state").textContent = {
        issued: "担当者の確認を待っています",
        claimed: "担当者が設定中です",
        completed: "設定が保存されました。お店で受信を確認してください。",
        expired: "有効期限が切れました",
        revoked: "依頼を取り消しました",
      }[value.state];
      $("request-expiry").textContent =
        new Intl.DateTimeFormat("ja-JP", {
          timeZone: "Asia/Tokyo",
          month: "numeric",
          day: "numeric",
          hour: "numeric",
          minute: "2-digit",
        }).format(new Date(value.expires_at)) + "（日本時間）";
      $("request-link").value = link;
      $("link-box").hidden = !link;
      $("revoke").hidden = terminal;
      if (terminal) {
        pendingBody = null;
        requestId = crypto.randomUUID();
        $("recipient").disabled = false;
      }
    }
    async function refresh() {
      if (!id) return;
      render(await request(scoped(`${endpoint}/${id}`)));
    }
    function poll() {
      later(async () => {
        if (
          polls >= 60 ||
          ["completed", "revoked", "expired"].includes(current?.state)
        )
          return;
        if (document.visibilityState === "visible" && !busy && id) {
          polls += 1;
          await action(refresh);
        }
        poll();
      }, 10000);
    }
    $("request-form").addEventListener("submit", (event) => {
      event.preventDefault();
      action(async () => {
        if (!canCreate) return;
        if (!pendingBody) {
          id = null;
          pendingBody = {
            handoff: {
              request_id: requestId,
              provider,
              ...(inboxId ? { inbox_id: inboxId } : {}),
              recipient: $("recipient").value.trim(),
            },
          };
          keepUrl();
        }
        $("recipient").disabled = true;
        try {
          render(await request(scoped(endpoint), pendingBody));
          pendingBody = null;
          $("recipient").value = "";
          message("リンクを担当者へ渡してください。");
          polls = 0;
          poll();
        } catch (failure) {
          if (failure.status && failure.status < 500) {
            pendingBody = null;
            $("recipient").disabled = false;
            throw failure;
          }
          // Preserve the same key and payload after an uncertain creation response.
          message(
            "作成結果を確認できませんでした。同じボタンで結果を確認できます。",
          );
        }
      });
    });
    $("refresh").addEventListener("click", () => action(refresh));
    $("revoke").addEventListener("click", () =>
      action(async () => {
        if (!id) return;
        try {
          render(await request(scoped(`${endpoint}/${id}/revoke`), {}));
          message("依頼を取り消しました。");
        } catch (failure) {
          message("取消結果を確認できません。状況を確認してください。");
          throw failure;
        }
      }),
    );
    copy($("copy-link"), $("request-link"));
    if (id) {
      $("request-form").hidden = true;
      $("request-result").hidden = false;
      $("revoke").hidden = true;
      action(refresh).then(poll);
    } else keepUrl();
  }

  function portal() {
    const id = root.dataset.requestId;
    if (!uuid.test(id)) return error("依頼を確認できません。");
    const endpoint = `/toybaco/connections/help/${id}`;
    let token = location.hash.slice(1);
    let state = null;
    let cooldown = 0;
    let unknownSave = false;
    let navigating = false;
    window.addEventListener("pagehide", () => {
      token = "";
    });
    function consume() {
      token = "";
      history.replaceState(null, "", location.pathname);
    }
    function identity(value) {
      validState(value, ["issued", "claimed", "completed"]);
      if (typeof value.store_name !== "string" || value.store_name.length > 160)
        throw new Error("invalid store");
      if (state && value.provider !== state.provider)
        throw new Error("provider changed");
      state = value;
      $("store").textContent =
        `${value.store_name} · ${providerLabels[value.provider]}`;
      $("setup-step").textContent = `2 ${providerLabels[value.provider]}の設定`;
      $("identity").hidden = value.state !== "issued";
      if (value.state !== "issued") {
        consume();
        $("identity-step").removeAttribute("aria-current");
        $("setup-step").setAttribute("aria-current", "step");
      }
    }
    function renderLine(value) {
      identity(value);
      if (value.state === "issued") throw new Error("unverified");
      $("check-save").hidden = true;
      if (value.settings_saved === true && value.state === "completed") {
        const url = new URL(value.webhook_url);
        if (
          url.origin !== location.origin ||
          url.username ||
          url.password ||
          url.search ||
          url.hash ||
          !/^[0-9]{5,20}$/.test(value.line_channel_id) ||
          url.pathname !== `/webhooks/line/${value.line_channel_id}`
        )
          throw new Error("invalid webhook");
        unknownSave = false;
        $("line-form").hidden = true;
        $("saved").hidden = false;
        $("heading").textContent = "設定を保存しました";
        $("webhook-url").value = url.href;
        $("line-channel-secret").value = "";
        $("line-channel-token").value = "";
        message("続いて、LINE側のWebhookを設定します。");
      } else if (value.state === "claimed" && value.line_available === true) {
        unknownSave = false;
        $("heading").textContent = "LINEをつなぎましょう";
        $("line-form").hidden = false;
        if (value.line_channel_id) {
          if (!/^[0-9]{5,20}$/.test(value.line_channel_id))
            throw new Error("invalid channel");
          $("line-channel-id").value = value.line_channel_id;
          $("line-channel-id").readOnly = true;
        }
        message("");
      } else {
        $("line-form").hidden = true;
        error("接続設定は現在準備中です。時間をおいてお試しください。");
        $("check-save").hidden = false;
      }
    }
    function renderMail(value) {
      identity(value);
      if (
        !["gmail", "microsoft"].includes(value.provider) ||
        value.state === "issued"
      )
        throw new Error("unverified mail");
      $("line-form").hidden = true;
      $("saved").hidden = true;
      $("check-save").hidden = true;
      const complete = value.state === "completed";
      $("mail-saved").hidden = !complete;
      $("mail-connect").hidden = complete || value.mail_available !== true;
      $("heading").textContent = complete
        ? "メールを接続しました"
        : `${providerLabels[value.provider]}をつなぎましょう`;
      $("connect-mail").textContent = `${providerLabels[value.provider]}で接続`;
      if (!complete && value.mail_available !== true) {
        error("接続設定は現在準備中です。時間をおいてお試しください。");
        $("check-save").hidden = false;
      } else message("");
    }
    async function loadSetup() {
      if (!state) identity(await request(`${endpoint}/session`));
      if (state.provider === "line")
        renderLine(await request(`${endpoint}/line`));
      else renderMail(await request(`${endpoint}/mail`));
    }
    async function initialize() {
      try {
        const value = await request(`${endpoint}/session`);
        identity(value);
        return await loadSetup();
      } catch (failure) {
        if (failure.status !== 403) throw failure;
      }
      if (!secretPattern.test(token))
        return error("有効な依頼リンクを開いてください。");
      identity(await request(`${endpoint}/open`, { link_secret: token }));
      message("");
    }
    function showCode(value) {
      identity(value);
      $("verify-form").hidden = false;
      if (value.delivery_state === "uncertain")
        message(
          "メールの送信結果を確認できません。届いていなければ、1分後に再送できます。",
        );
      else message("メールに届いた確認コードを入力してください。");
      $("verification-code").focus();
    }
    $("send-code").addEventListener("click", () =>
      action(async () => {
        if (Date.now() < cooldown) return message("再送は1分後にできます。");
        cooldown = Date.now() + 60000;
        $("send-code").textContent = "確認コードを再送";
        try {
          showCode(await request(`${endpoint}/code`, { link_secret: token }));
        } catch (failure) {
          $("verify-form").hidden = false;
          if (!failure.status || failure.status >= 500)
            message(
              "届いた場合はコードを入力してください。再送は1分後にできます。",
            );
          throw failure;
        }
      }),
    );
    $("verify-form").addEventListener("submit", (event) => {
      event.preventDefault();
      action(async () => {
        try {
          const value = await request(`${endpoint}/verify`, {
            link_secret: token,
            verification_code: $("verification-code").value,
          });
          identity(value);
          $("verification-code").value = "";
          await loadSetup();
        } catch (failure) {
          if (
            failure.status === 422 &&
            Number.isInteger(failure.data?.verification_remaining)
          ) {
            message(
              `あと${failure.data.verification_remaining}回確認できます。`,
            );
          } else if (!failure.status || failure.status >= 500) {
            // A successful claim may have reached the server before the response was lost.
            try {
              await loadSetup();
              return;
            } catch {}
          }
          throw failure;
        }
      });
    });
    $("login").addEventListener("click", () =>
      action(async () => {
        try {
          identity(await request(`${endpoint}/login`, { link_secret: token }));
          await loadSetup();
        } catch {
          try {
            await loadSetup();
          } catch {
            error(
              "指定されたアカウントで確認できません。メールの確認コードをご利用ください。",
            );
          }
        }
      }),
    );
    $("connect-mail").addEventListener("click", () =>
      action(async () => {
        if (
          navigating ||
          !state ||
          state.state !== "claimed" ||
          !["gmail", "microsoft"].includes(state.provider)
        )
          return;
        const result = await request(`${endpoint}/mail`, {});
        const url = new URL(result.url);
        const target =
          state.provider === "gmail"
            ? "https://accounts.google.com/o/oauth2/v2/auth"
            : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize";
        const expected = new URL(target);
        const query = url.searchParams;
        const keys = [...query.keys()];
        if (
          new Set(keys).size !== keys.length ||
          url.origin !== expected.origin ||
          url.pathname !== expected.pathname ||
          url.username ||
          url.password ||
          url.hash ||
          query.get("redirect_uri") !==
            `${location.origin}/toybaco/connections/help/oauth/${state.provider}/callback` ||
          query.get("response_type") !== "code" ||
          query.get("code_challenge_method") !== "S256" ||
          !secretPattern.test(query.get("state") || "") ||
          !/^[A-Za-z0-9_-]{43}$/.test(query.get("code_challenge") || "") ||
          !query.get("client_id")
        ) {
          throw new Error("invalid authorization");
        }
        message("接続画面を開いています…");
        navigating = true;
        try {
          window.location.assign(url.href);
        } catch (failure) {
          navigating = false;
          throw failure;
        }
      }),
    );
    $("line-form").addEventListener("submit", (event) => {
      event.preventDefault();
      action(async () => {
        if (unknownSave || state?.state !== "claimed") return;
        const fields = {
          line_channel_id: $("line-channel-id").value.trim(),
          line_channel_secret: $("line-channel-secret").value.trim(),
          line_channel_token: $("line-channel-token").value.trim(),
        };
        message("LINEの情報を確認しています…");
        try {
          renderLine(await request(`${endpoint}/line`, { fields }, 30000));
        } catch (failure) {
          if (!failure.status || failure.status >= 500) {
            unknownSave = true;
            $("line-form").hidden = true;
            $("check-save").hidden = false;
            message("保存結果を確認できません。保存状況を確認してください。");
          } else {
            message("");
            throw failure;
          }
        } finally {
          fields.line_channel_secret = "";
          fields.line_channel_token = "";
        }
      });
    });
    $("check-save").addEventListener("click", () => action(loadSetup));
    copy($("copy-webhook"), $("webhook-url"));
    action(initialize);
  }
  if (root.dataset.mode === "owner") owner();
  else if (root.dataset.mode === "portal") portal();
})();
