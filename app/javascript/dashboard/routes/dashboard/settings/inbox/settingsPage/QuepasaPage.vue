<script>
import { useAlert } from 'dashboard/composables';
import InboxesAPI from 'dashboard/api/inboxes';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import SpinnerLoader from 'dashboard/components-next/spinner/Spinner.vue';

const FIELD_CONFIG = [
  ['groups', 'Grupos', 'Receber mensagens de grupos'],
  ['broadcasts', 'Broadcasts', 'Receber listas de transmissão'],
  ['direct', 'Mensagens diretas', 'Conversas individuais'],
  ['calls', 'Chamadas', 'Receber eventos de chamada'],
  ['readreceipts', 'Confirmações de leitura', 'Receber eventos de leitura'],
  ['readupdate', 'Marcar como lida ao receber', 'Atualizar leitura automaticamente'],
];

const AUTOMATION_FIELD_CONFIG = [
  ['typing_presence', 'Mostrar digitando', 'Exibir digitando no WhatsApp enquanto o agente escreve'],
  ['read_sync', 'Sincronizar leitura', 'Marcar como lido ou não lido também no WhatsApp'],
  ['archive_sync', 'Sincronizar arquivamento', 'Arquivar ao resolver e desarquivar ao reabrir'],
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
      automationSettings: {},
      connected: false,
      isLoading: false,
      isSaving: false,
      isHydrating: false,
      isRefreshingQr: false,
      saveTimer: null,
      connectionTimer: null,
      fields: FIELD_CONFIG,
      automationFields: AUTOMATION_FIELD_CONFIG,
    };
  },
  mounted() {
    this.fetchSettings();
  },
  beforeUnmount() {
    this.stopConnectionPolling();
    if (this.saveTimer) clearTimeout(this.saveTimer);
  },
  watch: {
    running() {
      this.queueAutoSave();
    },
    settings: {
      deep: true,
      handler() {
        this.queueAutoSave();
      },
    },
    automationSettings: {
      deep: true,
      handler() {
        this.queueAutoSave();
      },
    },
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
      this.isHydrating = true;
      try {
        const response = await InboxesAPI.getQuepasaSettings(this.inbox.id);
        this.applyQuepasaState(response.data, { replaceSettings: true });
      } catch (error) {
        useAlert(
          this.errorMessage(
            error,
            'Não foi possível carregar as configurações do WhatsApp API'
          )
        );
      } finally {
        this.isHydrating = false;
        this.isLoading = false;
      }
    },
    async refreshQrCode() {
      this.isRefreshingQr = true;
      try {
        const response = await InboxesAPI.getQuepasaQRCode(this.inbox.id);
        this.applyQuepasaState(response.data);
        this.qrCode = this.connected ? '' : response.data.qr_code;
        if (this.connected) {
          useAlert('WhatsApp conectado com sucesso');
          this.stopConnectionPolling();
        } else {
          this.startConnectionPolling();
        }
      } catch (error) {
        useAlert(this.errorMessage(error, 'Não foi possível gerar o QR Code'));
      } finally {
        this.isRefreshingQr = false;
      }
    },
    queueAutoSave() {
      if (this.isHydrating || this.isLoading) return;

      if (this.saveTimer) clearTimeout(this.saveTimer);
      this.saveTimer = setTimeout(() => this.saveSettings({ silent: true }), 250);
    },
    async saveSettings() {
      this.isSaving = true;
      try {
        const response = await InboxesAPI.updateQuepasaSettings(this.inbox.id, {
          running: this.running,
          settings: this.settings,
          automation_settings: this.automationSettings,
        });
        this.applyQuepasaState(response.data);
      } catch (error) {
        useAlert(
          this.errorMessage(error, 'Não foi possível salvar as configurações')
        );
        this.fetchSettings();
      } finally {
        this.isSaving = false;
      }
    },
    applyQuepasaState(data = {}, { replaceSettings = false } = {}) {
      this.isHydrating = true;
      if (replaceSettings || data.settings) {
        this.settings = data.settings || this.settings || {};
      }
      if (replaceSettings || data.automation_settings) {
        this.automationSettings =
          data.automation_settings || this.automationSettings || {};
      }
      this.updateConnectionState(data);
      this.running =
        typeof data.running === 'boolean' ? data.running : this.running;
      if (this.connected) {
        this.qrCode = '';
        this.stopConnectionPolling();
      }
      this.$nextTick(() => {
        this.isHydrating = false;
      });
    },
    startConnectionPolling() {
      this.stopConnectionPolling();
      this.connectionTimer = setInterval(this.refreshConnectionState, 5000);
    },
    stopConnectionPolling() {
      if (!this.connectionTimer) return;

      clearInterval(this.connectionTimer);
      this.connectionTimer = null;
    },
    async refreshConnectionState() {
      try {
        const response = await InboxesAPI.getQuepasaSettings(this.inbox.id);
        const wasConnected = this.connected;
        this.applyQuepasaState(response.data);
        if (!wasConnected && this.connected) {
          useAlert('WhatsApp conectado com sucesso');
        }
      } catch {
        // Keep the QR visible and try again on the next polling tick.
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
        label="Conexão WhatsApp"
        :help-text="
          connected
            ? 'Número conectado e pronto para receber mensagens.'
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
                A sessão está ativa para enviar e receber mensagens.
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

      <SettingsFieldSection
        label="Automações do Chatwoot"
        help-text="Controle como as ações feitas no atendimento refletem no WhatsApp."
      >
        <div class="space-y-4">
          <SettingsToggleSection
            v-for="[key, label, description] in automationFields"
            :key="key"
            v-model="automationSettings[key]"
            :header="label"
            :description="description"
          />
        </div>
      </SettingsFieldSection>

      <div class="flex justify-end min-h-5">
        <span v-if="isSaving" class="text-sm text-n-slate-11">
          Salvando configurações...
        </span>
      </div>
    </template>
  </div>
</template>
