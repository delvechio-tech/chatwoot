<script>
import { mapGetters } from 'vuex';
import { useVuelidate } from '@vuelidate/core';
import { required } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import router from '../../../../index';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: { NextButton },
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      inboxName: '',
    };
  },
  computed: {
    ...mapGetters({ uiFlags: 'inboxes/getUIFlags' }),
  },
  validations: {
    inboxName: { required },
  },
  methods: {
    async createChannel() {
      this.v$.$touch();
      if (this.v$.$invalid) return;

      try {
        const inbox = await this.$store.dispatch('inboxes/createChannel', {
          name: this.inboxName?.trim(),
          channel: {
            type: 'whatsapp',
            provider: 'quepasa',
            provider_config: {},
          },
        });

        router.replace({
          name: 'settings_inboxes_add_agents',
          params: {
            page: 'new',
            inbox_id: inbox.id,
          },
        });
      } catch (error) {
        useAlert(error.message || 'Nao foi possivel criar a caixa WhatsApp API');
      }
    },
  },
};
</script>

<template>
  <form class="flex flex-wrap flex-col mx-0" @submit.prevent="createChannel">
    <div class="flex-shrink-0 flex-grow-0">
      <label :class="{ error: v$.inboxName.$error }">
        Nome da caixa de entrada
        <input
          v-model="inboxName"
          type="text"
          placeholder="Vendas WhatsApp"
          @blur="v$.inboxName.$touch"
        />
        <span v-if="v$.inboxName.$error" class="message">
          Informe um nome para a caixa de entrada
        </span>
      </label>
    </div>

    <p class="max-w-xl mb-4 text-sm leading-relaxed text-n-slate-11">
      Finalize a criacao da caixa e conecte seu numero nas configuracoes.
    </p>

    <div class="w-full mt-4">
      <NextButton
        :is-loading="uiFlags.isCreating"
        type="submit"
        solid
        blue
        label="Criar caixa"
      />
    </div>
  </form>
</template>
