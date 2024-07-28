"use strict";(self.webpackChunkfula_webui=self.webpackChunkfula_webui||[]).push([[34],{27034:(e,t,i)=>{i.r(t),i.d(t,{W3mModal:()=>c});var o=i(11525),n=i(76526),s=i(92662),a=i(94503);const r=s.AH`
  :host {
    z-index: var(--w3m-z-index);
    display: block;
    backface-visibility: hidden;
    will-change: opacity;
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    pointer-events: none;
    opacity: 0;
    background-color: var(--wui-cover);
    transition: opacity 0.2s var(--wui-ease-out-power-2);
    will-change: opacity;
  }

  :host(.open) {
    opacity: 1;
  }

  @keyframes zoom-in {
    0% {
      transform: scale(0.95) translateY(0);
    }
    100% {
      transform: scale(1) translateY(0);
    }
  }

  @keyframes slide-in {
    0% {
      transform: scale(1) translateY(50px);
    }
    100% {
      transform: scale(1) translateY(0);
    }
  }

  wui-card {
    max-width: var(--w3m-modal-width);
    width: 100%;
    position: relative;
    animation-duration: 0.2s;
    animation-name: zoom-in;
    animation-fill-mode: backwards;
    animation-timing-function: var(--wui-ease-out-power-2);
    outline: none;
  }

  wui-flex {
    overflow-x: hidden;
    overflow-y: auto;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 100%;
    height: 100%;
  }

  @media (max-height: 700px) and (min-width: 431px) {
    wui-flex {
      align-items: flex-start;
    }

    wui-card {
      margin: var(--wui-spacing-xxl) 0px;
    }
  }

  @media (max-width: 430px) {
    wui-flex {
      align-items: flex-end;
    }

    wui-card {
      max-width: 100%;
      border-bottom-left-radius: 0;
      border-bottom-right-radius: 0;
      border-bottom: none;
      animation-name: slide-in;
    }
  }
`;var l=function(e,t,i,o){var n,s=arguments.length,a=s<3?t:null===o?o=Object.getOwnPropertyDescriptor(t,i):o;if("object"==typeof Reflect&&"function"==typeof Reflect.decorate)a=Reflect.decorate(e,t,i,o);else for(var r=e.length-1;r>=0;r--)(n=e[r])&&(a=(s<3?n(a):s>3?n(t,i,a):n(t,i))||a);return s>3&&a&&Object.defineProperty(t,i,a),a};const d="scroll-lock";let c=class extends s.WF{constructor(){super(),this.unsubscribe=[],this.abortController=void 0,this.open=o.W3.state.open,this.caipAddress=o.Uj.state.caipAddress,this.isSiweEnabled=o.Hd.state.isSiweEnabled,this.connected=o.Uj.state.isConnected,this.loading=o.W3.state.loading,this.initializeTheming(),o.Np.prefetch(),this.unsubscribe.push(o.W3.subscribeKey("open",(e=>e?this.onOpen():this.onClose())),o.W3.subscribeKey("loading",(e=>{this.loading=e,this.onNewAddress(o.Uj.state.caipAddress)})),o.Uj.subscribeKey("isConnected",(e=>this.connected=e)),o.Uj.subscribeKey("caipAddress",(e=>this.onNewAddress(e))),o.Hd.subscribeKey("isSiweEnabled",(e=>this.isSiweEnabled=e))),o.En.sendEvent({type:"track",event:"MODAL_LOADED"})}disconnectedCallback(){this.unsubscribe.forEach((e=>e())),this.onRemoveKeyboardListener()}render(){return this.open?s.qy`
          <wui-flex @click=${this.onOverlayClick.bind(this)}>
            <wui-card role="alertdialog" aria-modal="true" tabindex="0">
              <w3m-header></w3m-header>
              <w3m-router></w3m-router>
              <w3m-snackbar></w3m-snackbar>
            </wui-card>
          </wui-flex>
          <w3m-tooltip></w3m-tooltip>
        `:null}async onOverlayClick(e){e.target===e.currentTarget&&await this.handleClose()}async handleClose(){if(this.isSiweEnabled){const{SIWEController:e}=await Promise.all([i.e(826),i.e(860),i.e(683)]).then(i.bind(i,64860));"success"!==e.state.status&&this.connected&&await o.x4.disconnect()}o.W3.close()}initializeTheming(){const{themeVariables:e,themeMode:t}=o.Wn.state,i=n.UiHelperUtil.getColorTheme(t);(0,n.initializeTheming)(e,i)}onClose(){this.open=!1,this.classList.remove("open"),this.onScrollUnlock(),o.Pt.hide(),this.onRemoveKeyboardListener()}onOpen(){this.open=!0,this.classList.add("open"),this.onScrollLock(),this.onAddKeyboardListener()}onScrollLock(){const e=document.createElement("style");e.dataset.w3m=d,e.textContent="\n      body {\n        touch-action: none;\n        overflow: hidden;\n        overscroll-behavior: contain;\n      }\n      w3m-modal {\n        pointer-events: auto;\n      }\n    ",document.head.appendChild(e)}onScrollUnlock(){const e=document.head.querySelector(`style[data-w3m="${d}"]`);e&&e.remove()}onAddKeyboardListener(){this.abortController=new AbortController;const e=this.shadowRoot?.querySelector("wui-card");e?.focus(),window.addEventListener("keydown",(t=>{if("Escape"===t.key)this.handleClose();else if("Tab"===t.key){const{tagName:i}=t.target;!i||i.includes("W3M-")||i.includes("WUI-")||e?.focus()}}),this.abortController)}onRemoveKeyboardListener(){this.abortController?.abort(),this.abortController=void 0}async onNewAddress(e){if(!this.connected||this.loading)return;const t=o.wE.getPlainAddress(this.caipAddress),n=o.wE.getPlainAddress(e),s=o.wE.getNetworkId(this.caipAddress),a=o.wE.getNetworkId(e);if(this.caipAddress=e,this.isSiweEnabled){const{SIWEController:e}=await Promise.all([i.e(826),i.e(860),i.e(683)]).then(i.bind(i,64860)),o=await e.getSession();if(o&&t&&n&&t!==n)return void(e.state._client?.options.signOutOnAccountChange&&(await e.signOut(),this.onSiweNavigation()));if(o&&s&&a&&s!==a)return void(e.state._client?.options.signOutOnNetworkChange&&(await e.signOut(),this.onSiweNavigation()));this.onSiweNavigation()}}onSiweNavigation(){this.open?o.IN.push("ConnectingSiwe"):o.W3.open({view:"ConnectingSiwe"})}};c.styles=r,l([(0,a.wk)()],c.prototype,"open",void 0),l([(0,a.wk)()],c.prototype,"caipAddress",void 0),l([(0,a.wk)()],c.prototype,"isSiweEnabled",void 0),l([(0,a.wk)()],c.prototype,"connected",void 0),l([(0,a.wk)()],c.prototype,"loading",void 0),c=l([(0,n.customElement)("w3m-modal")],c)}}]);