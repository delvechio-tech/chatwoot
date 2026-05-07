<script>
import { useAlert } from 'dashboard/composables';
import InboxesAPI from 'dashboard/api/inboxes';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import SpinnerLoader from 'dashboard/components-next/spinner/Spinner.vue';

const FIELD_CONFIG = [
  ['groups', 'Grupos', 'Receber mensagens de grupos'],
  ['broadcasts', 'Broadcasts', 'Receber listas de transmissao'],
  ['direct', 'Mensagens diretas', 'Conversas individuais'],
  ['calls', 'Chamadas', 'Receber eventos de chamada'],
  ['readreceipts', 'Confirmacoes de leitura', 'Receber eventos de leitura'],
  ['readupdate', 'Marcar como lida ao receber', 'Atualizar leitura automaticamente'],
];

export default {
  components: {
    SettingsFieldSection,
    SettingsToggleSection,
    NextButton,
    SpinnerLoader,
  },
  props: {
    inbox: {
      type: Object,
      required: true,
    },
  },
  data() {
    return {
      qrCode: '',
      running: true,
      settings: {},
      connected: false,
      isLoading: false,
      isSaving: false,
      isRefreshingQr: false,
      fields: FIELD_CONFIG,
    };
  },
  mounted() {
    this.fetchSettings();
  },
  methods: {
    errorMessage(error, fallback) {
      return (
        error?.response?.data?.error ||
        error?.response?.data?.message ||
        error.message ||
        fallback
      );
    },
    async fetchSettings() {
      this.isLoading = true;
      try {
        const response = await InboxesAPI.getQuepasaSettings(this.inbox.id);
        this.settings = response.data.settings || {};
        this.updateConnectionState(response.data);
        this.running =
          typeof response.data.running === 'boolean'
            ? response.data.running
            : true;
      } catch (error) {
        useAlert(
          this.errorMessage(
            error,
            'Nao foi possivel carregar as configuracoes do WhatsApp API'
          )
        );
      } finally {
        this.isLoading = false;
      }
    },
    async refreshQrCode() {
      this.isRefreshingQr = true;
      try {
        const response = await InboxesAPI.getQuepasaQRCode(this.inbox.id);
        this.updateConnectionState(response.data);
        this.qrCode = this.connected ? '' : response.data.qr_code;
        this.settings = response.data.settings || this.settings;
        this.running =
          typeof response.data.running === 'boolean'
            ? response.data.running
            : this.running;
      } catch (error) {
        useAlert(this.errorMessage(error, 'Nao foi possivel gerar o QR Code'));
      } finally {
        this.isRefreshingQr = false;
      }
    },
    async saveSettings() {
      this.isSaving = true;
      try {
        const response = await InboxesAPI.updateQuepasaSettings(this.inbox.id, {
          running: this.running,
          settings: this.settings,
        });
        this.settings = response.data.settings || this.settings;
        this.updateConnectionState(response.data);
        this.running =
          typeof response.data.running === 'boolean'
            ? response.data.running
            : this.running;
        useAlert('Configuracoes do WhatsApp API atualizadas');
      } catch (error) {
        useAlert(
          this.errorMessage(error, 'Nao foi possivel salvar as configuracoes')
        );
      } finally {
        this.isSaving = false;
      }
    },
    updateConnectionState(data = {}) {
      const info = data.info || {};
      const server = info.server || info;
      this.connected = Boolean(
        data.connected ||
          server.verified === true ||
          server.Verified === true ||
          server.wid ||
          server.Wid
      );
      if (this.connected) this.qrCode = '';
    },
  },
};
</script>

<template>
  <div class="space-y-6">
    <div v-if="isLoading" class="flex items-center justify-center py-10">
      <SpinnerLoader :size="28" />
    </div>

    <template v-else>
      <SettingsFieldSection
        label="Conexao WhatsApp"
        :help-text="
          connected
            ? 'Numero conectado e pronto para receber mensagens.'
            : 'Gere o QR Code e leia pelo WhatsApp em Aparelhos conectados.'
        "
      >
        <div v-if="connected" class="flex flex-col gap-3 items-start">
          <div
            class="flex items-center gap-3 rounded-xl outline outline-1 -outline-offset-1 outline-n-weak px-5 py-4"
          >
            <span class="i-lucide-circle-check size-5 text-n-teal-10" />
            <div>
              <p class="text-sm font-medium text-n-slate-12">
                Conectado com sucesso
              </p>
              <p class="text-sm text-n-slate-11">
                A sessao esta ativa para enviar e receber mensagens.
              </p>
            </div>
          </div>
          <NextButton
            :is-loading="isRefreshingQr"
            label="Gerar novo QR Code"
            color="slate"
            @click="refreshQrCode"
          />
        </div>
        <div v-else class="flex flex-col gap-4 items-start">
          <div
            class="flex items-center justify-center w-72 h-72 rounded-xl outline outline-1 -outline-offset-1 outline-n-weak bg-white"
          >
            <img
              v-if="qrCode"
              :src="qrCode"
              alt="QR Code WhatsApp"
              class="w-64 h-64"
            />
            <span v-else class="text-sm text-n-slate-11">
              Gere um QR Code para conectar
            </span>
          </div>
          <NextButton
            :is-loading="isRefreshingQr"
            label="Gerar QR Code"
            @click="refreshQrCode"
          />
        </div>
      </SettingsFieldSection>

      <SettingsToggleSection
        v-model="running"
        header="Bot ativo"
        :description="
          running
            ? 'Recebendo e enviando mensagens pelo Quepasa'
            : 'Bot pausado no Quepasa'
        "
      />

      <SettingsToggleSection
        v-for="[key, label, description] in fields"
        :key="key"
        v-model="settings[key]"
        :header="label"
        :description="description"
      />

      <div class="flex justify-end">
        <NextButton
          :is-loading="isSaving"
          label="Salvar configuracoes"
          @click="saveSettings"
        />
      </div>
    </template>
  </div>
</template>
