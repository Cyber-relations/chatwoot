let queued = Promise.resolve();
const resetGeneration = () => window.toybacoWidgetResetGeneration || 0;

const enqueue = (task, resetAtEnqueue, invalidateReads = true) => {
  const result = queued.catch(() => {}).then(async () => {
    if (resetAtEnqueue !== resetGeneration()) return undefined;
    const operation = (window.toybacoWidgetOperationGeneration || 0) + 1;
    window.toybacoWidgetOperationGeneration = operation;
    window.toybacoWidgetActiveOperation = operation;
    if (invalidateReads) {
      window.toybacoWidgetIdentityGeneration = (window.toybacoWidgetIdentityGeneration || 0) + 1;
    }
    try {
      return await task(operation);
    } finally {
      if (window.toybacoWidgetActiveOperation === operation) window.toybacoWidgetActiveOperation = undefined;
    }
  });
  queued = result;
  return result;
};

export const runIdentityOperation = (task, { invalidateReads = true } = {}) => window.toybacoHttpSession
  ? enqueue(task, resetGeneration(), invalidateReads) : task(undefined);

export const runIdentityReset = task => {
  window.toybacoWidgetResetGeneration = resetGeneration() + 1;
  // Cancel old reads immediately, while allowing an already executing identity
  // operation to install its confirmed proof before reset sends DELETE.
  window.toybacoWidgetIdentityGeneration = (window.toybacoWidgetIdentityGeneration || 0) + 1;
  return enqueue(task, resetGeneration());
};
