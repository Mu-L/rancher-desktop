<script lang="ts">
import { Card } from '@rancher/components';
import { defineComponent } from 'vue';

export default defineComponent({
  name:       'troubleshooting-line-item',
  components: { Card },
});
</script>
<template>
  <card
    class="troubleshooting-line-item"
    :show-highlight-border="false"
  >
    <template #title>
      <slot name="title" />
    </template>
    <template #body>
      <slot name="description" />
      <span class="options">
        <slot name="options" />
      </span>
    </template>
    <template #actions>
      <slot name="actions" />
    </template>
  </card>
</template>

<style lang="scss" scoped>
  .options {
    margin-top: 0.5rem;
  }

  // Override card styles from @rancher/components, we can remove this once the component gets refactor.
  .card-container {
    border-radius: 0;
    box-shadow: none;
    margin: 0;
  }
</style>
