import { mount } from '@vue/test-utils';
import AttachmentOmissions from '../AttachmentOmissions.vue';

describe('AttachmentOmissions', () => {
  it('shows every filename independently of other attachments or bubble type', () => {
    const wrapper = mount(AttachmentOmissions, {
      props: {
        omissions: [
          { filename: 'first.html', reason: 'File type not supported' },
          { filename: 'second.svg', reason: 'File type not supported' },
        ],
      },
    });

    expect(wrapper.findAll('li')).toHaveLength(2);
    expect(wrapper.text()).toContain('first.html');
    expect(wrapper.text()).toContain('second.svg');
  });

  it('renders an untrusted filename as text without a link or HTML', () => {
    const filename = '<img src=x onerror=alert(1)>.svg';
    const wrapper = mount(AttachmentOmissions, {
      props: { omissions: [{ filename }] },
    });

    expect(wrapper.text()).toContain(filename);
    expect(wrapper.find('img').exists()).toBe(false);
    expect(wrapper.find('a').exists()).toBe(false);
  });

  it('renders nothing when no file was omitted', () => {
    expect(mount(AttachmentOmissions).find('ul').exists()).toBe(false);
  });
});
