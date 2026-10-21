import { shallowMount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import { vi, describe, it, expect, beforeEach, afterEach } from 'vitest';
import ComposeConversation from '../ComposeConversation.vue';
import ContactAPI from 'dashboard/api/contacts';
import { useAlert } from 'dashboard/composables';
import { mutations } from 'dashboard/store/modules/contacts/mutations';
import { getters } from 'dashboard/store/modules/contacts/getters';
import types from 'dashboard/store/mutation-types';

vi.mock('dashboard/api/contacts');
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({ fetchSignatureFlagFromUISettings: () => false }),
}));
vi.mock('shared/helpers/mitt', () => ({ emitter: { emit: vi.fn() } }));
vi.mock(
  'dashboard/components-next/NewConversation/components/ComposeNewConversationForm.vue',
  () => ({
    default: {
      name: 'ComposeNewConversationForm',
      props: [
        'selectedContact',
        'targetInbox',
        'formState',
        'isFetchingInboxes',
      ],
      template: '<section />',
    },
  })
);
vi.mock('dashboard/components-next/popover/Popover.vue', () => ({
  default: {
    name: 'Popover',
    emits: ['show', 'hide'],
    methods: {
      hide() {
        this.$emit('hide');
      },
    },
    template: '<div><slot name="content" /></div>',
  },
}));

let store;
let wrapper;
let createConversation;
const inbox = {
  id: 7,
  name: 'Synthetic email',
  channel_type: 'Channel::Email',
  email: 'inbox@example.invalid',
};
const contact = {
  id: 12,
  name: 'Synthetic recipient',
  email: 'recipient@example.invalid',
};

beforeEach(() => {
  createConversation = vi.fn().mockResolvedValue({ account_id: 1, id: 22 });
  store = createStore({
    modules: {
      contacts: {
        namespaced: true,
        state: () => ({
          records: {
            12: {
              ...contact,
              contact_inboxes: [{ source_id: contact.email, inbox }],
            },
          },
          sortOrder: [12],
          uiFlags: {},
        }),
        mutations,
        getters,
      },
    },
    getters: {
      getCurrentUser: () => ({ id: 3 }),
      'globalConfig/get': () => ({ directUploadsEnabled: false }),
      'contactConversations/getUIFlags': () => ({}),
      getMessageSignature: () => '',
      'inboxes/getInboxes': () => [inbox],
    },
    actions: {
      'inboxes/get': vi.fn(),
      'contactConversations/create': createConversation,
    },
  });
  ContactAPI.getContactableInboxes.mockResolvedValue({
    data: { payload: [{ source_id: contact.email, inbox }] },
  });
  wrapper = shallowMount(ComposeConversation, {
    props: { contactId: '12' },
    global: {
      plugins: [store],
      stubs: { Popover: false, ComposeNewConversationForm: false },
    },
  });
});

afterEach(() => wrapper.unmount());

describe('new email from a contact', () => {
  it('refetches sendable inboxes after an avatar/update response replaces the contact cache', async () => {
    const form = wrapper.findComponent({ name: 'ComposeNewConversationForm' });
    expect(form.props('selectedContact').contactInboxes).toHaveLength(1);
    // contacts/update and contacts/deleteAvatar return a contact without contact_inboxes.
    store.commit(`contacts/${types.EDIT_CONTACT}`, {
      ...contact,
      thumbnail: '',
    });
    await flushPromises();
    expect(form.props('selectedContact').contactInboxes).toEqual([]);
    wrapper.findComponent({ name: 'Popover' }).vm.$emit('show');
    await flushPromises();
    expect(ContactAPI.getContactableInboxes).toHaveBeenCalledWith(12);
    expect(form.props('selectedContact').contactInboxes).toMatchObject([
      { id: 7, sourceId: contact.email },
    ]);
  });

  it('reports inbox lookup failure, retains the draft and retries on reopening', async () => {
    const form = wrapper.findComponent({ name: 'ComposeNewConversationForm' });
    Object.assign(form.props('formState'), {
      message: 'Synthetic unsent draft',
      subject: 'Synthetic subject',
    });
    ContactAPI.getContactableInboxes.mockRejectedValueOnce(
      new Error('synthetic HTTP failure')
    );
    wrapper.findComponent({ name: 'Popover' }).vm.$emit('show');
    await flushPromises();
    expect(useAlert).toHaveBeenCalled();
    expect(form.props('formState')).toMatchObject({
      message: 'Synthetic unsent draft',
      subject: 'Synthetic subject',
    });
    expect(form.props('isFetchingInboxes')).toBe(false);
    wrapper.findComponent({ name: 'Popover' }).vm.$emit('hide');
    wrapper.findComponent({ name: 'Popover' }).vm.$emit('show');
    await flushPromises();
    expect(ContactAPI.getContactableInboxes).toHaveBeenCalledTimes(2);
    expect(form.props('selectedContact').contactInboxes).toHaveLength(1);
  });

  it('keeps an API lookup with no sendable inboxes distinct from an HTTP failure', async () => {
    ContactAPI.getContactableInboxes.mockResolvedValueOnce({
      data: { payload: [] },
    });
    wrapper.findComponent({ name: 'Popover' }).vm.$emit('show');
    await flushPromises();
    const form = wrapper.findComponent({ name: 'ComposeNewConversationForm' });
    expect(form.props('selectedContact').contactInboxes).toEqual([]);
    expect(form.props('isFetchingInboxes')).toBe(false);
    expect(useAlert).not.toHaveBeenCalled();
    expect(createConversation).not.toHaveBeenCalled();
  });

  it('preserves the subject, body, recipients and files when the new conversation POST fails', async () => {
    createConversation.mockRejectedValueOnce(
      new Error('synthetic POST failure')
    );
    const form = wrapper.findComponent({ name: 'ComposeNewConversationForm' });
    const draft = {
      message: 'Synthetic draft',
      subject: 'Synthetic subject',
      ccEmails: 'cc@example.invalid',
      bccEmails: 'bcc@example.invalid',
      attachedFiles: [{ blobSignedId: 'synthetic-file' }],
    };
    Object.assign(form.props('formState'), draft);
    const payload = {
      inboxId: 7,
      contactId: 12,
      message: { content: draft.message },
      mailSubject: draft.subject,
    };
    form.vm.$emit('createConversation', { payload, isFromWhatsApp: false });
    await flushPromises();
    expect(createConversation).toHaveBeenCalledWith(expect.anything(), {
      params: payload,
      isFromWhatsApp: false,
    });
    expect(form.props('formState')).toEqual(draft);
    expect(wrapper.emitted('close')).toBeUndefined();
    expect(useAlert).toHaveBeenCalledWith(
      '作成結果を確認できませんでした。入力内容は保持されています。会話一覧で送信状況を確認してください。'
    );
  });

  it('restores a still available selected inbox after reopening without losing the draft', async () => {
    const form = wrapper.findComponent({ name: 'ComposeNewConversationForm' });
    form.vm.$emit('updateTargetInbox', { ...inbox, sourceId: contact.email });
    Object.assign(form.props('formState'), {
      message: 'Synthetic draft',
      subject: 'Synthetic subject',
    });
    wrapper.findComponent({ name: 'Popover' }).vm.$emit('show');
    await flushPromises();
    expect(form.props('targetInbox')).toMatchObject({
      id: 7,
      sourceId: contact.email,
    });
    expect(form.props('formState')).toMatchObject({
      message: 'Synthetic draft',
      subject: 'Synthetic subject',
    });
  });

  it('ignores a slow inbox response after choosing a different recipient', async () => {
    await wrapper.setProps({ contactId: null });
    let resolveOld;
    ContactAPI.getContactableInboxes.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveOld = resolve;
        })
    );
    const form = wrapper.findComponent({ name: 'ComposeNewConversationForm' });
    form.vm.$emit('updateSelectedContact', contact);
    const nextContact = { id: 13, email: 'next@example.invalid' };
    ContactAPI.getContactableInboxes.mockResolvedValueOnce({
      data: { payload: [{ source_id: nextContact.email, inbox }] },
    });
    form.vm.$emit('updateSelectedContact', nextContact);
    await flushPromises();
    resolveOld({ data: { payload: [{ source_id: contact.email, inbox }] } });
    await flushPromises();
    expect(form.props('selectedContact')).toMatchObject({
      id: 13,
      contactInboxes: [{ sourceId: nextContact.email }],
    });
    expect(form.props('isFetchingInboxes')).toBe(false);
  });

  it('ignores a slow response from before closing and retries for the same selected recipient', async () => {
    await wrapper.setProps({ contactId: null });
    let resolveOld;
    ContactAPI.getContactableInboxes.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveOld = resolve;
        })
    );
    const form = wrapper.findComponent({ name: 'ComposeNewConversationForm' });
    form.vm.$emit('updateSelectedContact', contact);
    Object.assign(form.props('formState'), {
      message: 'Synthetic retained draft',
      subject: 'Synthetic subject',
    });
    wrapper.findComponent({ name: 'Popover' }).vm.$emit('hide');
    wrapper.findComponent({ name: 'Popover' }).vm.$emit('show');
    await flushPromises();
    expect(ContactAPI.getContactableInboxes).toHaveBeenCalledTimes(2);
    expect(form.props('selectedContact').contactInboxes).toHaveLength(1);
    resolveOld({ data: { payload: [] } });
    await flushPromises();
    expect(form.props('selectedContact').contactInboxes).toHaveLength(1);
    expect(form.props('formState')).toMatchObject({
      message: 'Synthetic retained draft',
      subject: 'Synthetic subject',
    });
    expect(form.props('isFetchingInboxes')).toBe(false);
  });

  it('does not submit a second new conversation while the first POST is pending', async () => {
    let resolveCreate;
    createConversation.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveCreate = resolve;
        })
    );
    const form = wrapper.findComponent({ name: 'ComposeNewConversationForm' });
    const event = {
      payload: {
        inboxId: 7,
        contactId: 12,
        message: { content: 'Synthetic first email' },
      },
      isFromWhatsApp: false,
    };
    form.vm.$emit('createConversation', event);
    form.vm.$emit('createConversation', event);
    expect(createConversation).toHaveBeenCalledTimes(1);
    resolveCreate({ account_id: 1, id: 22 });
    await flushPromises();
  });
});
