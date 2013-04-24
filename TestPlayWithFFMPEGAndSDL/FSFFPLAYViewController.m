//
//  FSFFPLAYViewController.m
//  TestPlayWithFFMPEGAndSDL
//
//  Created by  on 12-12-14.
//  Copyright (c) 2012年 __MyCompanyName__. All rights reserved.
//

#import "FSFFPLAYViewController.h"

@implementation FSFFPLAYViewController


/* options specified by the user */
static AVInputFormat *file_iformat;
static const char *input_filename;
//static const char *window_title;
//static int fs_screen_width;
//static int fs_screen_height;
static int screen_width  = 0;
static int screen_height = 0;
static int audio_disable;
static int video_disable;
static int wanted_stream[AVMEDIA_TYPE_NB] = {
    [AVMEDIA_TYPE_AUDIO]    = -1,
    [AVMEDIA_TYPE_VIDEO]    = -1,
    [AVMEDIA_TYPE_SUBTITLE] = -1,
};
static int seek_by_bytes = -1;
static int display_disable;
static int show_status = 1;
static int av_sync_type = AV_SYNC_AUDIO_MASTER;
static int64_t start_time = AV_NOPTS_VALUE;
static int64_t duration = AV_NOPTS_VALUE;
static int workaround_bugs = 1;
static int fast = 0;
static int genpts = 0;
static int lowres = 0;
static int idct = FF_IDCT_AUTO;
static enum AVDiscard skip_frame       = AVDISCARD_DEFAULT;
static enum AVDiscard skip_idct        = AVDISCARD_DEFAULT;
static enum AVDiscard skip_loop_filter = AVDISCARD_DEFAULT;
static int error_concealment = 3;
static int decoder_reorder_pts = -1;
static int autoexit;
static int exit_on_keydown;
static int exit_on_mousedown;
static int loop = 1;
static int framedrop = -1;
static int infinite_buffer = 0;
static enum ShowMode show_mode = SHOW_MODE_NONE;
static const char *audio_codec_name;
static const char *subtitle_codec_name;
static const char *video_codec_name;
static int rdftspeed = 20;
//#if CONFIG_AVFILTER
//static char *vfilters = NULL;
//#endif

/* current context */
//static int is_full_screen;
static int64_t audio_callback_time;

static AVPacket flush_pkt;

static KxMovieDecoder *kxMoviedecoder;

static KxVideoFrame *kxVideoFrame;

#define FF_ALLOC_EVENT   (SDL_USEREVENT)
#define FF_REFRESH_EVENT (SDL_USEREVENT + 1)
#define FF_QUIT_EVENT    (SDL_USEREVENT + 2)

//static SDL_Surface *screen;

void av_noreturn exit_program(int ret)
{
    exit(ret);
}

static int packet_queue_put_private(PacketQueue *q, AVPacket *pkt)
{
    AVPacketList *pkt1;
    
    if (q->abort_request)
        return -1;
    
    pkt1 = av_malloc(sizeof(AVPacketList));
    if (!pkt1)
        return -1;
    pkt1->pkt = *pkt;
    pkt1->next = NULL;
    
    if (!q->last_pkt)
        q->first_pkt = pkt1;
    else
        q->last_pkt->next = pkt1;
    q->last_pkt = pkt1;
    q->nb_packets++;
    q->size += pkt1->pkt.size + sizeof(*pkt1);
    /* XXX: should duplicate packet data in DV case */
    SDL_CondSignal(q->cond);
    return 0;
}

static int packet_queue_put(PacketQueue *q, AVPacket *pkt)
{
    int ret;
    
    /* duplicate the packet */
    if (pkt != &flush_pkt && av_dup_packet(pkt) < 0)
        return -1;
    
    SDL_LockMutex(q->mutex);
    ret = packet_queue_put_private(q, pkt);
    SDL_UnlockMutex(q->mutex);
    
    if (pkt != &flush_pkt && ret < 0)
        av_free_packet(pkt);
    
    return ret;
}

/* packet queue handling */
static void packet_queue_init(PacketQueue *q)
{
    memset(q, 0, sizeof(PacketQueue));
    q->mutex = SDL_CreateMutex();
    q->cond = SDL_CreateCond();
    q->abort_request = 1;
}

static void packet_queue_flush(PacketQueue *q)
{
    AVPacketList *pkt, *pkt1;
    
    SDL_LockMutex(q->mutex);
    for (pkt = q->first_pkt; pkt != NULL; pkt = pkt1) {
        pkt1 = pkt->next;
        av_free_packet(&pkt->pkt);
        av_freep(&pkt);
    }
    q->last_pkt = NULL;
    q->first_pkt = NULL;
    q->nb_packets = 0;
    q->size = 0;
    SDL_UnlockMutex(q->mutex);
}

static void packet_queue_destroy(PacketQueue *q)
{
    packet_queue_flush(q);
    SDL_DestroyMutex(q->mutex);
    SDL_DestroyCond(q->cond);
}

static void packet_queue_abort(PacketQueue *q)
{
    SDL_LockMutex(q->mutex);
    
    q->abort_request = 1;
    
    SDL_CondSignal(q->cond);
    
    SDL_UnlockMutex(q->mutex);
}

static void packet_queue_start(PacketQueue *q)
{
    SDL_LockMutex(q->mutex);
    q->abort_request = 0;
    packet_queue_put_private(q, &flush_pkt);
    SDL_UnlockMutex(q->mutex);
}

/* return < 0 if aborted, 0 if no packet and > 0 if packet.  */
static int packet_queue_get(PacketQueue *q, AVPacket *pkt, int block)
{
    AVPacketList *pkt1;
    int ret;
    
    SDL_LockMutex(q->mutex);
    
    for (;;) {
        if (q->abort_request) {
            ret = -1;
            break;
        }
        
        pkt1 = q->first_pkt;
        if (pkt1) {
            q->first_pkt = pkt1->next;
            if (!q->first_pkt)
                q->last_pkt = NULL;
            q->nb_packets--;
            q->size -= pkt1->pkt.size + sizeof(*pkt1);
            *pkt = pkt1->pkt;
            av_free(pkt1);
            ret = 1;
            break;
        } else if (!block) {
            ret = 0;
            break;
        } else {
            SDL_CondWait(q->cond, q->mutex);
        }
    }
    SDL_UnlockMutex(q->mutex);
    return ret;
}
//
//static inline void fill_rectangle(SDL_Surface *screen,
//                                  int x, int y, int w, int h, int color)
//{
//    SDL_Rect rect;
//    rect.x = x;
//    rect.y = y;
//    rect.w = w;
//    rect.h = h;
//    SDL_FillRect(screen, &rect, color);
//}

//#define ALPHA_BLEND(a, oldp, newp, s)\
//((((oldp << s) * (255 - (a))) + (newp * (a))) / (255 << s))

#define RGBA_IN(r, g, b, a, s)\
{\
unsigned int v = ((const uint32_t *)(s))[0];\
a = (v >> 24) & 0xff;\
r = (v >> 16) & 0xff;\
g = (v >> 8) & 0xff;\
b = v & 0xff;\
}

//#define YUVA_IN(y, u, v, a, s, pal)\
//{\
//unsigned int val = ((const uint32_t *)(pal))[*(const uint8_t*)(s)];\
//a = (val >> 24) & 0xff;\
//y = (val >> 16) & 0xff;\
//u = (val >> 8) & 0xff;\
//v = val & 0xff;\
//}

#define YUVA_OUT(d, y, u, v, a)\
{\
((uint32_t *)(d))[0] = (a << 24) | (y << 16) | (u << 8) | v;\
}


#define BPP 1



static void free_subpicture(SubPicture *sp)
{
    avsubtitle_free(&sp->sub);
}

static void calculate_display_rect(SDL_Rect *rect, int scr_xleft, int scr_ytop, int scr_width, int scr_height, VideoPicture *vp)
{
    float aspect_ratio;
    int width, height, x, y;
    
    if (vp->sample_aspect_ratio.num == 0)
        aspect_ratio = 0;
    else
        aspect_ratio = av_q2d(vp->sample_aspect_ratio);
    
    if (aspect_ratio <= 0.0)
        aspect_ratio = 1.0;
    aspect_ratio *= (float)vp->width / (float)vp->height;
    
    /* XXX: we suppose the screen has a 1.0 pixel ratio */
    height = scr_height;
    width = ((int)rint(height * aspect_ratio)) & ~1;
    if (width > scr_width) {
        width = scr_width;
        height = ((int)rint(width / aspect_ratio)) & ~1;
    }
    x = (scr_width - width) / 2;
    y = (scr_height - height) / 2;
    rect->x = scr_xleft + x;
    rect->y = scr_ytop  + y;
    rect->w = FFMAX(width,  1);
    rect->h = FFMAX(height, 1);
}

static void stream_close(VideoState *is)
{
    VideoPicture *vp;
    int i;
    /* XXX: use a special url_shutdown call to abort parse cleanly */
    is->abort_request = 1;
    SDL_WaitThread(is->read_tid, NULL);
    SDL_WaitThread(is->refresh_tid, NULL);
    packet_queue_destroy(&is->videoq);
    packet_queue_destroy(&is->audioq);
    packet_queue_destroy(&is->subtitleq);
    
    /* free all pictures */
    for (i = 0; i < VIDEO_PICTURE_QUEUE_SIZE; i++) {
        vp = &is->pictq[i];
//#if CONFIG_AVFILTER
//        avfilter_unref_bufferp(&vp->picref);
//#endif
        if (vp->bmp) {
            SDL_FreeYUVOverlay(vp->bmp);
            vp->bmp = NULL;
        }
    }
    SDL_DestroyMutex(is->pictq_mutex);
    SDL_DestroyCond(is->pictq_cond);
    SDL_DestroyMutex(is->subpq_mutex);
    SDL_DestroyCond(is->subpq_cond);
    SDL_DestroyCond(is->continue_read_thread);
#if !CONFIG_AVFILTER
    if (is->img_convert_ctx)
        sws_freeContext(is->img_convert_ctx);
#endif
    av_free(is);
}

static void do_exit(VideoState *is)
{
    NSLog(@"退出程序");
    if (is) {
        stream_close(is);
    }
    av_lockmgr_register(NULL);
    uninit_opts();
//#if CONFIG_AVFILTER
//    avfilter_uninit();
//    av_freep(&vfilters);
//#endif
    avformat_network_deinit();
    if (show_status)
        printf("\n");
    SDL_Quit();
    av_log(NULL, AV_LOG_QUIET, "%s", "");
    exit(0);
}

static void sigterm_handler(int sig)
{
    exit(123);
}


static int refresh_thread(void *opaque)
{
    VideoState *is= opaque;
    while (!is->abort_request) {
        SDL_Event event;
        event.type = FF_REFRESH_EVENT;
        event.user.data1 = opaque;
        if (!is->refresh && (!is->paused || is->force_refresh)) {
            is->refresh = 1;
            SDL_PushEvent(&event);
        }
        //FIXME ideally we should wait the correct time but SDLs event passing is so slow it would be silly
        av_usleep(is->audio_st && is->show_mode != SHOW_MODE_VIDEO ? rdftspeed*1000 : 5000);
    }
    return 0;
}

/* get the current audio clock value */
static double get_audio_clock(VideoState *is)
{
    if (is->paused) {
        return is->audio_current_pts;
    } else {
        return is->audio_current_pts_drift + av_gettime() / 1000000.0;
    }
}

/* get the current video clock value */
static double get_video_clock(VideoState *is)
{
    if (is->paused) {
        return is->video_current_pts;
    } else {
        return is->video_current_pts_drift + av_gettime() / 1000000.0;
    }
}

/* get the current external clock value */
static double get_external_clock(VideoState *is)
{
    int64_t ti;
    ti = av_gettime();
    return is->external_clock + ((ti - is->external_clock_time) * 1e-6);
}

/* get the current master clock value */
static double get_master_clock(VideoState *is)
{
    double val;
    
    if (is->av_sync_type == AV_SYNC_VIDEO_MASTER) {
        if (is->video_st)
            val = get_video_clock(is);
        else
            val = get_audio_clock(is);
    } else if (is->av_sync_type == AV_SYNC_AUDIO_MASTER) {
        if (is->audio_st)
            val = get_audio_clock(is);
        else
            val = get_video_clock(is);
    } else {
        val = get_external_clock(is);
    }
    return val;
}

/* seek in the stream */
static void stream_seek(VideoState *is, int64_t pos, int64_t rel, int seek_by_bytes)
{
    if (!is->seek_req) {
        is->seek_pos = pos;
        is->seek_rel = rel;
        is->seek_flags &= ~AVSEEK_FLAG_BYTE;
        if (seek_by_bytes)
            is->seek_flags |= AVSEEK_FLAG_BYTE;
        is->seek_req = 1;
    }
}

/* pause or resume the video */
static void stream_toggle_pause(VideoState *is)
{
    if (is->paused) {
        is->frame_timer += av_gettime() / 1000000.0 + is->video_current_pts_drift - is->video_current_pts;
        if (is->read_pause_return != AVERROR(ENOSYS)) {
            is->video_current_pts = is->video_current_pts_drift + av_gettime() / 1000000.0;
        }
        is->video_current_pts_drift = is->video_current_pts - av_gettime() / 1000000.0;
    }
    is->paused = !is->paused;
}

static double compute_target_delay(double delay, VideoState *is)
{
    double sync_threshold, diff;
    
    /* update delay to follow master synchronisation source */
    if (((is->av_sync_type == AV_SYNC_AUDIO_MASTER && is->audio_st) ||
         is->av_sync_type == AV_SYNC_EXTERNAL_CLOCK)) {
        /* if video is slave, we try to correct big delays by
         duplicating or deleting a frame */
        diff = get_video_clock(is) - get_master_clock(is);
        
        /* skip or repeat frame. We take into account the
         delay to compute the threshold. I still don't know
         if it is the best guess */
        sync_threshold = FFMAX(AV_SYNC_THRESHOLD, delay);
        if (fabs(diff) < AV_NOSYNC_THRESHOLD) {
            if (diff <= -sync_threshold)
                delay = 0;
            else if (diff >= sync_threshold)
                delay = 2 * delay;
        }
    }
    
    av_dlog(NULL, "video: delay=%0.3f A-V=%f\n",
            delay, -diff);
    
    return delay;
}

static void pictq_next_picture(VideoState *is) {
    /* update queue size and signal for next picture */
    if (++is->pictq_rindex == VIDEO_PICTURE_QUEUE_SIZE)
        is->pictq_rindex = 0;
    
    SDL_LockMutex(is->pictq_mutex);
    is->pictq_size--;
    SDL_CondSignal(is->pictq_cond);
    SDL_UnlockMutex(is->pictq_mutex);
}

static void pictq_prev_picture(VideoState *is) {
    VideoPicture *prevvp;
    /* update queue size and signal for the previous picture */
    prevvp = &is->pictq[(is->pictq_rindex + VIDEO_PICTURE_QUEUE_SIZE - 1) % VIDEO_PICTURE_QUEUE_SIZE];
    if (prevvp->allocated && !prevvp->skip) {
        SDL_LockMutex(is->pictq_mutex);
        if (is->pictq_size < VIDEO_PICTURE_QUEUE_SIZE - 1) {
            if (--is->pictq_rindex == -1)
                is->pictq_rindex = VIDEO_PICTURE_QUEUE_SIZE - 1;
            is->pictq_size++;
        }
        SDL_CondSignal(is->pictq_cond);
        SDL_UnlockMutex(is->pictq_mutex);
    }
}

static void update_video_pts(VideoState *is, double pts, int64_t pos) {
    double time = av_gettime() / 1000000.0;
    /* update current video pts */
    is->video_current_pts = pts;
    is->video_current_pts_drift = is->video_current_pts - time;
    is->video_current_pos = pos;
    is->frame_last_pts = pts;
}

/* called to display each frame */
static void video_refresh(void *opaque)
{
    NSLog(@"%s  %d", __FUNCTION__, __LINE__);
    VideoState *is = opaque;
    VideoPicture *vp;
    double time;
    
    SubPicture *sp, *sp2;
    
    if (is->video_st) {
        if (is->force_refresh)
            pictq_prev_picture(is);
    retry:
        if (is->pictq_size == 0) {
            SDL_LockMutex(is->pictq_mutex);
            if (is->frame_last_dropped_pts != AV_NOPTS_VALUE && is->frame_last_dropped_pts > is->frame_last_pts) {
                update_video_pts(is, is->frame_last_dropped_pts, is->frame_last_dropped_pos);
                is->frame_last_dropped_pts = AV_NOPTS_VALUE;
            }
            SDL_UnlockMutex(is->pictq_mutex);
            // nothing to do, no picture to display in the que
        } else {
            double last_duration, duration, delay;
            /* dequeue the picture */
            vp = &is->pictq[is->pictq_rindex];
            
            if (vp->skip) {
                pictq_next_picture(is);
                goto retry;
            }
            
            if (is->paused)
                goto display;
            
            /* compute nominal last_duration */
            last_duration = vp->pts - is->frame_last_pts;
            if (last_duration > 0 && last_duration < 10.0) {
                /* if duration of the last frame was sane, update last_duration in video state */
                is->frame_last_duration = last_duration;
            }
            delay = compute_target_delay(is->frame_last_duration, is);
            
            time= av_gettime()/1000000.0;
            if (time < is->frame_timer + delay)
                return;
            
            if (delay > 0)
                is->frame_timer += delay * FFMAX(1, floor((time-is->frame_timer) / delay));
            
            SDL_LockMutex(is->pictq_mutex);
            update_video_pts(is, vp->pts, vp->pos);
            SDL_UnlockMutex(is->pictq_mutex);
            
            if (is->pictq_size > 1) {
                VideoPicture *nextvp = &is->pictq[(is->pictq_rindex + 1) % VIDEO_PICTURE_QUEUE_SIZE];
                duration = nextvp->pts - vp->pts;
                if((framedrop>0 || (framedrop && is->audio_st)) && time > is->frame_timer + duration){
                    is->frame_drops_late++;
                    pictq_next_picture(is);
                    goto retry;
                }
            }
            
            if (is->subtitle_st) {
                if (is->subtitle_stream_changed) {
                    SDL_LockMutex(is->subpq_mutex);
                    
                    while (is->subpq_size) {
                        free_subpicture(&is->subpq[is->subpq_rindex]);
                        
                        /* update queue size and signal for next picture */
                        if (++is->subpq_rindex == SUBPICTURE_QUEUE_SIZE)
                            is->subpq_rindex = 0;
                        
                        is->subpq_size--;
                    }
                    is->subtitle_stream_changed = 0;
                    
                    SDL_CondSignal(is->subpq_cond);
                    SDL_UnlockMutex(is->subpq_mutex);
                } else {
                    if (is->subpq_size > 0) {
                        sp = &is->subpq[is->subpq_rindex];
                        
                        if (is->subpq_size > 1)
                            sp2 = &is->subpq[(is->subpq_rindex + 1) % SUBPICTURE_QUEUE_SIZE];
                        else
                            sp2 = NULL;
                        
                        if ((is->video_current_pts > (sp->pts + ((float) sp->sub.end_display_time / 1000)))
                            || (sp2 && is->video_current_pts > (sp2->pts + ((float) sp2->sub.start_display_time / 1000))))
                        {
                            free_subpicture(sp);
                            
                            /* update queue size and signal for next picture */
                            if (++is->subpq_rindex == SUBPICTURE_QUEUE_SIZE)
                                is->subpq_rindex = 0;
                            
                            SDL_LockMutex(is->subpq_mutex);
                            is->subpq_size--;
                            SDL_CondSignal(is->subpq_cond);
                            SDL_UnlockMutex(is->subpq_mutex);
                        }
                    }
                }
            }
            
        display:
            
            pictq_next_picture(is);
        }
    }
    
    is->force_refresh = 0;
    if (show_status) {
        static int64_t last_time;
        int64_t cur_time;
        int aqsize, vqsize, sqsize;
        double av_diff;
        
        cur_time = av_gettime();
        if (!last_time || (cur_time - last_time) >= 30000) {
            aqsize = 0;
            vqsize = 0;
            sqsize = 0;
            if (is->audio_st)
                aqsize = is->audioq.size;
            if (is->video_st)
                vqsize = is->videoq.size;
            if (is->subtitle_st)
                sqsize = is->subtitleq.size;
            av_diff = 0;
            if (is->audio_st && is->video_st)
                av_diff = get_audio_clock(is) - get_video_clock(is);
            printf("%7.2f A-V:%7.3f fd=%4d aq=%5dKB vq=%5dKB sq=%5dB f=%"PRId64"/%"PRId64"   \r",
                   get_master_clock(is),
                   av_diff,
                   is->frame_drops_early + is->frame_drops_late,
                   aqsize / 1024,
                   vqsize / 1024,
                   sqsize,
                   is->video_st ? is->video_st->codec->pts_correction_num_faulty_dts : 0,
                   is->video_st ? is->video_st->codec->pts_correction_num_faulty_pts : 0);
            fflush(stdout);
            last_time = cur_time;
        }
    }
}

/* allocate a picture (needs to do that in main thread to avoid
 potential locking problems */
static void alloc_picture(VideoState *is)
{
    VideoPicture *vp;
    
    vp = &is->pictq[is->pictq_windex];

    
//#if CONFIG_AVFILTER
//    avfilter_unref_bufferp(&vp->picref);
//#endif
    
    SDL_LockMutex(is->pictq_mutex);
    vp->allocated = 1;
    SDL_CondSignal(is->pictq_cond);
    SDL_UnlockMutex(is->pictq_mutex);
}

static int queue_picture(VideoState *is, AVFrame *src_frame, double pts1, int64_t pos)
{
    VideoPicture *vp;
    double frame_delay, pts = pts1;
    
    /* compute the exact PTS for the picture if it is omitted in the stream
     * pts1 is the dts of the pkt / pts of the frame */
    if (pts != 0) {
        /* update video clock with pts, if present */
        is->video_clock = pts;
    } else {
        pts = is->video_clock;
    }
    /* update video clock for next frame */
    frame_delay = av_q2d(is->video_st->codec->time_base);
    /* for MPEG2, the frame can be repeated, so we update the
     clock accordingly */
    frame_delay += src_frame->repeat_pict * (frame_delay * 0.5);
    is->video_clock += frame_delay;
    
#if defined(DEBUG_SYNC) && 0
    printf("frame_type=%c clock=%0.3f pts=%0.3f\n",
           av_get_picture_type_char(src_frame->pict_type), pts, pts1);
#endif
    
    /* wait until we have space to put a new picture */
    SDL_LockMutex(is->pictq_mutex);
    
    /* keep the last already displayed picture in the queue */
    while (is->pictq_size >= VIDEO_PICTURE_QUEUE_SIZE - 2 &&
           !is->videoq.abort_request) {
        SDL_CondWait(is->pictq_cond, is->pictq_mutex);
    }
    SDL_UnlockMutex(is->pictq_mutex);
    
    if (is->videoq.abort_request)
        return -1;
    
    vp = &is->pictq[is->pictq_windex];
    
//#if CONFIG_AVFILTER
//    vp->sample_aspect_ratio = ((AVFilterBufferRef *)src_frame->opaque)->video->sample_aspect_ratio;
//#else
    vp->sample_aspect_ratio = av_guess_sample_aspect_ratio(is->ic, is->video_st, src_frame);
//#endif
    
    /* alloc or resize hardware picture buffer */
//    if (!vp->bmp || vp->reallocate || !vp->allocated ||
    if ( vp->reallocate || !vp->allocated ||
        vp->width  != src_frame->width ||
        vp->height != src_frame->height) {
        SDL_Event event;
        
        vp->allocated  = 0;
        vp->reallocate = 0;
        vp->width = src_frame->width;
        vp->height = src_frame->height;
        
        /* the allocation must be done in the main thread to avoid
         locking problems. */
        event.type = FF_ALLOC_EVENT;
        event.user.data1 = is;
        SDL_PushEvent(&event);
        
        /* wait until the picture is allocated */
        SDL_LockMutex(is->pictq_mutex);
        while (!vp->allocated && !is->videoq.abort_request) {
            SDL_CondWait(is->pictq_cond, is->pictq_mutex);
        }
        /* if the queue is aborted, we have to pop the pending ALLOC event or wait for the allocation to complete */
//        if (is->videoq.abort_request && SDL_PeepEvents(&event, 1, SDL_GETEVENT, SDL_EVENTMASK(FF_ALLOC_EVENT)) != 1) {
        if (is->videoq.abort_request && SDL_PeepEvents(&event, 1, SDL_GETEVENT, SDL_USEREVENT, SDL_LASTEVENT) != 1) {
            while (!vp->allocated) {
                SDL_CondWait(is->pictq_cond, is->pictq_mutex);
            }
        }
        SDL_UnlockMutex(is->pictq_mutex);
        
        if (is->videoq.abort_request)
            return -1;
    }

//#if CONFIG_AVFILTER
//        avfilter_unref_bufferp(&vp->picref);
//        vp->picref = src_frame->opaque;
//#endif
    SDL_LockMutex(is->pictq_mutex);
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    @synchronized (kxVideoFrame) {

        if (!kxVideoFrame) {
            kxVideoFrame = [kxMoviedecoder handleVieoFrameWithFrame:src_frame andvideoCodecCtx:is->video_st->codec];

        }

    }
    [pool release];
    SDL_UnlockMutex(is->pictq_mutex);
        vp->pts = pts;
        vp->pos = pos;
        vp->skip = 0;
        
        /* now we can update the picture count */
        if (++is->pictq_windex == VIDEO_PICTURE_QUEUE_SIZE)
            is->pictq_windex = 0;
        SDL_LockMutex(is->pictq_mutex);
        is->pictq_size++;
        SDL_UnlockMutex(is->pictq_mutex);

    return 0;
}

static int get_video_frame(VideoState *is, AVFrame *frame, int64_t *pts, AVPacket *pkt)
{
    SDL_SetThreadPriority(SDL_THREAD_PRIORITY_HIGH);

    int got_picture, i;
    
    if (packet_queue_get(&is->videoq, pkt, 1) < 0)
        return -1;
    
    if (pkt->data == flush_pkt.data) {
        avcodec_flush_buffers(is->video_st->codec);
        
        SDL_LockMutex(is->pictq_mutex);
        // Make sure there are no long delay timers (ideally we should just flush the que but thats harder)
        for (i = 0; i < VIDEO_PICTURE_QUEUE_SIZE; i++) {
            is->pictq[i].skip = 1;
        }
        while (is->pictq_size && !is->videoq.abort_request) {
            SDL_CondWait(is->pictq_cond, is->pictq_mutex);
        }
        is->video_current_pos = -1;
        is->frame_last_pts = AV_NOPTS_VALUE;
        is->frame_last_duration = 0;
        is->frame_timer = (double)av_gettime() / 1000000.0;
        is->frame_last_dropped_pts = AV_NOPTS_VALUE;
        SDL_UnlockMutex(is->pictq_mutex);
        
        return 0;
    }
    
    if(avcodec_decode_video2(is->video_st->codec, frame, &got_picture, pkt) < 0)
        return 0;
    
    if (got_picture) {
        int ret = 1;
        
        if (decoder_reorder_pts == -1) {
            *pts = av_frame_get_best_effort_timestamp(frame);
        } else if (decoder_reorder_pts) {
            *pts = frame->pkt_pts;
        } else {
            *pts = frame->pkt_dts;
        }
        
        if (*pts == AV_NOPTS_VALUE) {
            *pts = 0;
        }
        
        if (((is->av_sync_type == AV_SYNC_AUDIO_MASTER && is->audio_st) || is->av_sync_type == AV_SYNC_EXTERNAL_CLOCK) &&
            (framedrop>0 || (framedrop && is->audio_st))) {
            SDL_LockMutex(is->pictq_mutex);
            if (is->frame_last_pts != AV_NOPTS_VALUE && *pts) {
                double clockdiff = get_video_clock(is) - get_master_clock(is);
                double dpts = av_q2d(is->video_st->time_base) * *pts;
                double ptsdiff = dpts - is->frame_last_pts;
                if (fabs(clockdiff) < AV_NOSYNC_THRESHOLD &&
                    ptsdiff > 0 && ptsdiff < AV_NOSYNC_THRESHOLD &&
                    clockdiff + ptsdiff - is->frame_last_filter_delay < 0) {
                    is->frame_last_dropped_pos = pkt->pos;
                    is->frame_last_dropped_pts = dpts;
                    is->frame_drops_early++;
                    ret = 0;
                }
            }
            SDL_UnlockMutex(is->pictq_mutex);
        }
        
        return ret;
    }
    return 0;
}

//#if CONFIG_AVFILTER
//static int configure_filtergraph(AVFilterGraph *graph, const char *filtergraph,
//                                 AVFilterContext *source_ctx, AVFilterContext *sink_ctx)
//{
//    int ret;
//    AVFilterInOut *outputs = NULL, *inputs = NULL;
//    
//    if (filtergraph) {
//        outputs = avfilter_inout_alloc();
//        inputs  = avfilter_inout_alloc();
//        if (!outputs || !inputs) {
//            ret = AVERROR(ENOMEM);
//            goto fail;
//        }
//        
//        outputs->name       = av_strdup("in");
//        outputs->filter_ctx = source_ctx;
//        outputs->pad_idx    = 0;
//        outputs->next       = NULL;
//        
//        inputs->name        = av_strdup("out");
//        inputs->filter_ctx  = sink_ctx;
//        inputs->pad_idx     = 0;
//        inputs->next        = NULL;
//        
//        if ((ret = avfilter_graph_parse(graph, filtergraph, &inputs, &outputs, NULL)) < 0)
//            goto fail;
//    } else {
//        if ((ret = avfilter_link(source_ctx, 0, sink_ctx, 0)) < 0)
//            goto fail;
//    }
//    
//    return avfilter_graph_config(graph, NULL);
//fail:
//    avfilter_inout_free(&outputs);
//    avfilter_inout_free(&inputs);
//    return ret;
//}
//
//static int configure_video_filters(AVFilterGraph *graph, VideoState *is, const char *vfilters)
//{
//    static const enum PixelFormat pix_fmts[] = { PIX_FMT_YUV420P, PIX_FMT_NONE };
//    char sws_flags_str[128];
//    char buffersrc_args[256];
//    int ret;
//    AVBufferSinkParams *buffersink_params = av_buffersink_params_alloc();
//    AVFilterContext *filt_src = NULL, *filt_out = NULL, *filt_format, *filt_crop;
//    AVCodecContext *codec = is->video_st->codec;
//    
//    snprintf(sws_flags_str, sizeof(sws_flags_str), "flags=%d", sws_flags);
//    graph->scale_sws_opts = av_strdup(sws_flags_str);
//    
//    snprintf(buffersrc_args, sizeof(buffersrc_args),
//             "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d",
//             codec->width, codec->height, codec->pix_fmt,
//             is->video_st->time_base.num, is->video_st->time_base.den,
//             codec->sample_aspect_ratio.num, codec->sample_aspect_ratio.den);
//    
//    if ((ret = avfilter_graph_create_filter(&filt_src,
//                                            avfilter_get_by_name("buffer"),
//                                            "ffplay_buffer", buffersrc_args, NULL,
//                                            graph)) < 0)
//        return ret;
//    
//    buffersink_params->pixel_fmts = pix_fmts;
//    ret = avfilter_graph_create_filter(&filt_out,
//                                       avfilter_get_by_name("ffbuffersink"),
//                                       "ffplay_buffersink", NULL, buffersink_params, graph);
//    av_freep(&buffersink_params);
//    if (ret < 0)
//        return ret;
//    
//    /* SDL YUV code is not handling odd width/height for some driver
//     * combinations, therefore we crop the picture to an even width/height. */
//    if ((ret = avfilter_graph_create_filter(&filt_crop,
//                                            avfilter_get_by_name("crop"),
//                                            "ffplay_crop", "floor(in_w/2)*2:floor(in_h/2)*2", NULL, graph)) < 0)
//        return ret;
//    if ((ret = avfilter_graph_create_filter(&filt_format,
//                                            avfilter_get_by_name("format"),
//                                            "format", "yuv420p", NULL, graph)) < 0)
//        return ret;
//    if ((ret = avfilter_link(filt_crop, 0, filt_format, 0)) < 0)
//        return ret;
//    if ((ret = avfilter_link(filt_format, 0, filt_out, 0)) < 0)
//        return ret;
//    
//    if ((ret = configure_filtergraph(graph, vfilters, filt_src, filt_crop)) < 0)
//        return ret;
//    
//    is->in_video_filter  = filt_src;
//    is->out_video_filter = filt_out;
//    
//    return ret;
//}
//
//#endif  /* CONFIG_AVFILTER */

static int video_thread(void *arg)
{
    
    AVPacket pkt = { 0 };
    VideoState *is = arg;
    AVFrame *frame = avcodec_alloc_frame();
    int64_t pts_int = AV_NOPTS_VALUE, pos = -1;
    double pts;
    int ret;
    
//#if CONFIG_AVFILTER
//    AVCodecContext *codec = is->video_st->codec;
//    AVFilterGraph *graph = avfilter_graph_alloc();
//    AVFilterContext *filt_out = NULL, *filt_in = NULL;
//    int last_w = 0;
//    int last_h = 0;
//    enum PixelFormat last_format = -2;
//    
//    if (codec->codec->capabilities & CODEC_CAP_DR1) {
//        is->use_dr1 = 1;
//        codec->get_buffer     = codec_get_buffer;
//        codec->release_buffer = codec_release_buffer;
//        codec->opaque         = &is->buffer_pool;
//    }
//#endif
    
    for (;;) {
//#if CONFIG_AVFILTER
//        AVFilterBufferRef *picref;
//        AVRational tb;
//#endif

        while (is->paused && !is->videoq.abort_request)
            SDL_Delay(10);
        
        avcodec_get_frame_defaults(frame);
        av_free_packet(&pkt);
        
        ret = get_video_frame(is, frame, &pts_int, &pkt);
        if (ret < 0)
            goto the_end;
        
        if (!ret) {
            continue;
        }
        
//#if CONFIG_AVFILTER
//        if (   last_w != is->video_st->codec->width
//            || last_h != is->video_st->codec->height
//            || last_format != is->video_st->codec->pix_fmt) {
//            av_log(NULL, AV_LOG_INFO, "Frame changed from size:%dx%d to size:%dx%d\n",
//                   last_w, last_h, is->video_st->codec->width, is->video_st->codec->height);
//            avfilter_graph_free(&graph);
//            graph = avfilter_graph_alloc();
//            if ((ret = configure_video_filters(graph, is, vfilters)) < 0) {
//                SDL_Event event;
//                event.type = FF_QUIT_EVENT;
//                event.user.data1 = is;
//                SDL_PushEvent(&event);
//                av_free_packet(&pkt);
//                goto the_end;
//            }
//            filt_in  = is->in_video_filter;
//            filt_out = is->out_video_filter;
//            last_w = is->video_st->codec->width;
//            last_h = is->video_st->codec->height;
//            last_format = is->video_st->codec->pix_fmt;
//        }
//        
//        frame->pts = pts_int;
//        frame->sample_aspect_ratio = av_guess_sample_aspect_ratio(is->ic, is->video_st, frame);
//        if (is->use_dr1 && frame->opaque) {
//            FrameBuffer      *buf = frame->opaque;
//            AVFilterBufferRef *fb = avfilter_get_video_buffer_ref_from_arrays(
//                                                                              frame->data, frame->linesize,
//                                                                              AV_PERM_READ | AV_PERM_PRESERVE,
//                                                                              frame->width, frame->height,
//                                                                              frame->format);
//            
//            avfilter_copy_frame_props(fb, frame);
//            fb->buf->priv           = buf;
//            fb->buf->free           = filter_release_buffer;
//            
//            buf->refcount++;
//            av_buffersrc_add_ref(filt_in, fb, AV_BUFFERSRC_FLAG_NO_COPY);
//            
//        } else
//            av_buffersrc_write_frame(filt_in, frame);
//        
//        av_free_packet(&pkt);
//        
//        while (ret >= 0) {
//            is->frame_last_returned_time = av_gettime() / 1000000.0;
//            
//            ret = av_buffersink_get_buffer_ref(filt_out, &picref, 0);
//            if (ret < 0) {
//                ret = 0;
//                break;
//            }
//            
//            is->frame_last_filter_delay = av_gettime() / 1000000.0 - is->frame_last_returned_time;
//            if (fabs(is->frame_last_filter_delay) > AV_NOSYNC_THRESHOLD / 10.0)
//                is->frame_last_filter_delay = 0;
//            
//            avfilter_copy_buf_props(frame, picref);
//            
//            pts_int = picref->pts;
//            tb      = filt_out->inputs[0]->time_base;
//            pos     = picref->pos;
//            frame->opaque = picref;
//            
//            if (av_cmp_q(tb, is->video_st->time_base)) {
//                av_unused int64_t pts1 = pts_int;
//                pts_int = av_rescale_q(pts_int, tb, is->video_st->time_base);
//                av_dlog(NULL, "video_thread(): "
//                        "tb:%d/%d pts:%"PRId64" -> tb:%d/%d pts:%"PRId64"\n",
//                        tb.num, tb.den, pts1,
//                        is->video_st->time_base.num, is->video_st->time_base.den, pts_int);
//            }
//            pts = pts_int * av_q2d(is->video_st->time_base);
//            ret = queue_picture(is, frame, pts, pos);
//        }
//#else
        pts = pts_int * av_q2d(is->video_st->time_base);
        ret = queue_picture(is, frame, pts, pkt.pos);
//#endif
        
        if (ret < 0)
            goto the_end;
        
        if (is->step)
            stream_toggle_pause(is);
    }
the_end:
    avcodec_flush_buffers(is->video_st->codec);
//#if CONFIG_AVFILTER
//    avfilter_graph_free(&graph);
//#endif
    av_free_packet(&pkt);
    avcodec_free_frame(&frame);
    return 0;
}

static int subtitle_thread(void *arg)
{
    VideoState *is = arg;
    SubPicture *sp;
    AVPacket pkt1, *pkt = &pkt1;
    int got_subtitle;
    double pts;
    int i, j;
    int r, g, b, y, u, v, a;
    
    for (;;) {
        while (is->paused && !is->subtitleq.abort_request) {
            SDL_Delay(10);
        }
        if (packet_queue_get(&is->subtitleq, pkt, 1) < 0)
            break;
        
        if (pkt->data == flush_pkt.data) {
            avcodec_flush_buffers(is->subtitle_st->codec);
            continue;
        }
        SDL_LockMutex(is->subpq_mutex);
        while (is->subpq_size >= SUBPICTURE_QUEUE_SIZE &&
               !is->subtitleq.abort_request) {
            SDL_CondWait(is->subpq_cond, is->subpq_mutex);
        }
        SDL_UnlockMutex(is->subpq_mutex);
        
        if (is->subtitleq.abort_request)
            return 0;
        
        sp = &is->subpq[is->subpq_windex];
        
        /* NOTE: ipts is the PTS of the _first_ picture beginning in
         this packet, if any */
        pts = 0;
        if (pkt->pts != AV_NOPTS_VALUE)
            pts = av_q2d(is->subtitle_st->time_base) * pkt->pts;
        
        avcodec_decode_subtitle2(is->subtitle_st->codec, &sp->sub,
                                 &got_subtitle, pkt);
        if (got_subtitle && sp->sub.format == 0) {
            if (sp->sub.pts != AV_NOPTS_VALUE)
                pts = sp->sub.pts / (double)AV_TIME_BASE;
            sp->pts = pts;
            
            for (i = 0; i < sp->sub.num_rects; i++)
            {
                for (j = 0; j < sp->sub.rects[i]->nb_colors; j++)
                {
                    RGBA_IN(r, g, b, a, (uint32_t*)sp->sub.rects[i]->pict.data[1] + j);
                    y = RGB_TO_Y_CCIR(r, g, b);
                    u = RGB_TO_U_CCIR(r, g, b, 0);
                    v = RGB_TO_V_CCIR(r, g, b, 0);
                    YUVA_OUT((uint32_t*)sp->sub.rects[i]->pict.data[1] + j, y, u, v, a);
                }
            }
            
            /* now we can update the picture count */
            if (++is->subpq_windex == SUBPICTURE_QUEUE_SIZE)
                is->subpq_windex = 0;
            SDL_LockMutex(is->subpq_mutex);
            is->subpq_size++;
            SDL_UnlockMutex(is->subpq_mutex);
        }
        av_free_packet(pkt);
    }
    return 0;
}

/* copy samples for viewing in editor window */
static void update_sample_display(VideoState *is, short *samples, int samples_size)
{
    int size, len;
    
    size = samples_size / sizeof(short);
    while (size > 0) {
        len = SAMPLE_ARRAY_SIZE - is->sample_array_index;
        if (len > size)
            len = size;
        memcpy(is->sample_array + is->sample_array_index, samples, len * sizeof(short));
        samples += len;
        is->sample_array_index += len;
        if (is->sample_array_index >= SAMPLE_ARRAY_SIZE)
            is->sample_array_index = 0;
        size -= len;
    }
}

/* return the wanted number of samples to get better sync if sync_type is video
 * or external master clock */
static int synchronize_audio(VideoState *is, int nb_samples)
{
    int wanted_nb_samples = nb_samples;
    
    /* if not master, then we try to remove or add samples to correct the clock */
    if (((is->av_sync_type == AV_SYNC_VIDEO_MASTER && is->video_st) ||
         is->av_sync_type == AV_SYNC_EXTERNAL_CLOCK)) {
        double diff, avg_diff;
        int min_nb_samples, max_nb_samples;
        
        diff = get_audio_clock(is) - get_master_clock(is);
        
        if (diff < AV_NOSYNC_THRESHOLD) {
            is->audio_diff_cum = diff + is->audio_diff_avg_coef * is->audio_diff_cum;
            if (is->audio_diff_avg_count < AUDIO_DIFF_AVG_NB) {
                /* not enough measures to have a correct estimate */
                is->audio_diff_avg_count++;
            } else {
                /* estimate the A-V difference */
                avg_diff = is->audio_diff_cum * (1.0 - is->audio_diff_avg_coef);
                
                if (fabs(avg_diff) >= is->audio_diff_threshold) {
                    wanted_nb_samples = nb_samples + (int)(diff * is->audio_src.freq);
                    min_nb_samples = ((nb_samples * (100 - SAMPLE_CORRECTION_PERCENT_MAX) / 100));
                    max_nb_samples = ((nb_samples * (100 + SAMPLE_CORRECTION_PERCENT_MAX) / 100));
                    wanted_nb_samples = FFMIN(FFMAX(wanted_nb_samples, min_nb_samples), max_nb_samples);
                }
                av_dlog(NULL, "diff=%f adiff=%f sample_diff=%d apts=%0.3f vpts=%0.3f %f\n",
                        diff, avg_diff, wanted_nb_samples - nb_samples,
                        is->audio_clock, is->video_clock, is->audio_diff_threshold);
            }
        } else {
            /* too big difference : may be initial PTS errors, so
             reset A-V filter */
            is->audio_diff_avg_count = 0;
            is->audio_diff_cum       = 0;
        }
    }
    
    return wanted_nb_samples;
}

/* decode one audio frame and returns its uncompressed size */
static int audio_decode_frame(VideoState *is, double *pts_ptr)
{
    AVPacket *pkt_temp = &is->audio_pkt_temp;
    AVPacket *pkt = &is->audio_pkt;
    AVCodecContext *dec = is->audio_st->codec;
    int len1, len2, data_size, resampled_data_size;
    int64_t dec_channel_layout;
    int got_frame;
    double pts;
    int new_packet = 0;
    int flush_complete = 0;
    int wanted_nb_samples;
    
    for (;;) {
        /* NOTE: the audio packet can contain several frames */
        while (pkt_temp->size > 0 || (!pkt_temp->data && new_packet)) {
            if (!is->frame) {
                if (!(is->frame = avcodec_alloc_frame()))
                    return AVERROR(ENOMEM);
            } else
                avcodec_get_frame_defaults(is->frame);
            
            if (is->paused)
                return -1;
            
            if (flush_complete)
                break;
            new_packet = 0;
            len1 = avcodec_decode_audio4(dec, is->frame, &got_frame, pkt_temp);
            if (len1 < 0) {
                /* if error, we skip the frame */
                pkt_temp->size = 0;
                break;
            }
            
            pkt_temp->data += len1;
            pkt_temp->size -= len1;
            
            if (!got_frame) {
                /* stop sending empty packets if the decoder is finished */
                if (!pkt_temp->data && dec->codec->capabilities & CODEC_CAP_DELAY)
                    flush_complete = 1;
                continue;
            }
            data_size = av_samples_get_buffer_size(NULL, dec->channels,
                                                   is->frame->nb_samples,
                                                   dec->sample_fmt, 1);
            
            dec_channel_layout =
            (dec->channel_layout && dec->channels == av_get_channel_layout_nb_channels(dec->channel_layout)) ?
            dec->channel_layout : av_get_default_channel_layout(dec->channels);
            wanted_nb_samples = synchronize_audio(is, is->frame->nb_samples);
            
            if (dec->sample_fmt    != is->audio_src.fmt            ||
                dec_channel_layout != is->audio_src.channel_layout ||
                dec->sample_rate   != is->audio_src.freq           ||
                (wanted_nb_samples != is->frame->nb_samples && !is->swr_ctx)) {
                swr_free(&is->swr_ctx);
                is->swr_ctx = swr_alloc_set_opts(NULL,
                                                 is->audio_tgt.channel_layout, is->audio_tgt.fmt, is->audio_tgt.freq,
                                                 dec_channel_layout,           dec->sample_fmt,   dec->sample_rate,
                                                 0, NULL);
                if (!is->swr_ctx || swr_init(is->swr_ctx) < 0) {
                    fprintf(stderr, "Cannot create sample rate converter for conversion of %d Hz %s %d channels to %d Hz %s %d channels!\n",
                            dec->sample_rate,   av_get_sample_fmt_name(dec->sample_fmt),   dec->channels,
                            is->audio_tgt.freq, av_get_sample_fmt_name(is->audio_tgt.fmt), is->audio_tgt.channels);
                    break;
                }
                is->audio_src.channel_layout = dec_channel_layout;
                is->audio_src.channels = dec->channels;
                is->audio_src.freq = dec->sample_rate;
                is->audio_src.fmt = dec->sample_fmt;
            }
            
            if (is->swr_ctx) {
                const uint8_t **in = (const uint8_t **)is->frame->extended_data;
                uint8_t *out[] = {is->audio_buf2};
                int out_count = sizeof(is->audio_buf2) / is->audio_tgt.channels / av_get_bytes_per_sample(is->audio_tgt.fmt);
                if (wanted_nb_samples != is->frame->nb_samples) {
                    if (swr_set_compensation(is->swr_ctx, (wanted_nb_samples - is->frame->nb_samples) * is->audio_tgt.freq / dec->sample_rate,
                                             wanted_nb_samples * is->audio_tgt.freq / dec->sample_rate) < 0) {
                        fprintf(stderr, "swr_set_compensation() failed\n");
                        break;
                    }
                }
                len2 = swr_convert(is->swr_ctx, out, out_count, in, is->frame->nb_samples);
                if (len2 < 0) {
                    fprintf(stderr, "swr_convert() failed\n");
                    break;
                }
                if (len2 == out_count) {
                    fprintf(stderr, "warning: audio buffer is probably too small\n");
                    swr_init(is->swr_ctx);
                }
                is->audio_buf = is->audio_buf2;
                resampled_data_size = len2 * is->audio_tgt.channels * av_get_bytes_per_sample(is->audio_tgt.fmt);
            } else {
                is->audio_buf = is->frame->data[0];
                resampled_data_size = data_size;
            }
            
            /* if no pts, then compute it */
            pts = is->audio_clock;
            *pts_ptr = pts;
            is->audio_clock += (double)data_size /
            (dec->channels * dec->sample_rate * av_get_bytes_per_sample(dec->sample_fmt));
#ifdef DEBUG
            {
                static double last_clock;
                printf("audio: delay=%0.3f clock=%0.3f pts=%0.3f\n",
                       is->audio_clock - last_clock,
                       is->audio_clock, pts);
                last_clock = is->audio_clock;
            }
#endif
            return resampled_data_size;
        }
        
        /* free the current packet */
        if (pkt->data)
            av_free_packet(pkt);
        memset(pkt_temp, 0, sizeof(*pkt_temp));
        
        if (is->paused || is->audioq.abort_request) {
            return -1;
        }
        
        if (is->audioq.nb_packets == 0)
            SDL_CondSignal(is->continue_read_thread);
        
        /* read next packet */
        if ((new_packet = packet_queue_get(&is->audioq, pkt, 1)) < 0)
            return -1;
        
        if (pkt->data == flush_pkt.data) {
            avcodec_flush_buffers(dec);
            flush_complete = 0;
        }
        
        *pkt_temp = *pkt;
        
        /* if update the audio clock with the pts */
        if (pkt->pts != AV_NOPTS_VALUE) {
            is->audio_clock = av_q2d(is->audio_st->time_base)*pkt->pts;
        }
    }
}

/* prepare a new audio buffer */
static void sdl_audio_callback(void *opaque, Uint8 *stream, int len)
{
    VideoState *is = opaque;
    int audio_size, len1;
    int bytes_per_sec;
    int frame_size = av_samples_get_buffer_size(NULL, is->audio_tgt.channels, 1, is->audio_tgt.fmt, 1);
    double pts;
    
    audio_callback_time = av_gettime();
    
    while (len > 0) {
        if (is->audio_buf_index >= is->audio_buf_size) {
            audio_size = audio_decode_frame(is, &pts);
            if (audio_size < 0) {
                /* if error, just output silence */
                is->audio_buf      = is->silence_buf;
                is->audio_buf_size = sizeof(is->silence_buf) / frame_size * frame_size;
            } else {
                if (is->show_mode != SHOW_MODE_VIDEO)
                    update_sample_display(is, (int16_t *)is->audio_buf, audio_size);
                is->audio_buf_size = audio_size;
            }
            is->audio_buf_index = 0;
        }
        len1 = is->audio_buf_size - is->audio_buf_index;
        if (len1 > len)
            len1 = len;
        memcpy(stream, (uint8_t *)is->audio_buf + is->audio_buf_index, len1);
        len -= len1;
        stream += len1;
        is->audio_buf_index += len1;
    }
    bytes_per_sec = is->audio_tgt.freq * is->audio_tgt.channels * av_get_bytes_per_sample(is->audio_tgt.fmt);
    is->audio_write_buf_size = is->audio_buf_size - is->audio_buf_index;
    /* Let's assume the audio driver that is used by SDL has two periods. */
    is->audio_current_pts = is->audio_clock - (double)(2 * is->audio_hw_buf_size + is->audio_write_buf_size) / bytes_per_sec;
    is->audio_current_pts_drift = is->audio_current_pts - audio_callback_time / 1000000.0;
}

static int audio_open(void *opaque, int64_t wanted_channel_layout, int wanted_nb_channels, int wanted_sample_rate, struct AudioParams *audio_hw_params)
{
    SDL_AudioSpec wanted_spec, spec;
    const char *env;
    const int next_nb_channels[] = {0, 0, 1, 6, 2, 6, 4, 6};
    
    env = SDL_getenv("SDL_AUDIO_CHANNELS");
    if (env) {
        wanted_nb_channels = atoi(env);
        wanted_channel_layout = av_get_default_channel_layout(wanted_nb_channels);
    }
    if (!wanted_channel_layout || wanted_nb_channels != av_get_channel_layout_nb_channels(wanted_channel_layout)) {
        wanted_channel_layout = av_get_default_channel_layout(wanted_nb_channels);
        wanted_channel_layout &= ~AV_CH_LAYOUT_STEREO_DOWNMIX;
    }
    wanted_spec.channels = av_get_channel_layout_nb_channels(wanted_channel_layout);
    wanted_spec.freq = wanted_sample_rate;
    if (wanted_spec.freq <= 0 || wanted_spec.channels <= 0) {
        fprintf(stderr, "Invalid sample rate or channel count!\n");
        return -1;
    }
    wanted_spec.format = AUDIO_S16SYS;
    wanted_spec.silence = 0;
    wanted_spec.samples = SDL_AUDIO_BUFFER_SIZE;
    wanted_spec.callback = sdl_audio_callback;
    wanted_spec.userdata = opaque;
    while (SDL_OpenAudio(&wanted_spec, &spec) < 0) {
        fprintf(stderr, "SDL_OpenAudio (%d channels): %s\n", wanted_spec.channels, SDL_GetError());
        wanted_spec.channels = next_nb_channels[FFMIN(7, wanted_spec.channels)];
        if (!wanted_spec.channels) {
            fprintf(stderr, "No more channel combinations to try, audio open failed\n");
            return -1;
        }
        wanted_channel_layout = av_get_default_channel_layout(wanted_spec.channels);
    }
    if (spec.format != AUDIO_S16SYS) {
        fprintf(stderr, "SDL advised audio format %d is not supported!\n", spec.format);
        return -1;
    }
    if (spec.channels != wanted_spec.channels) {
        wanted_channel_layout = av_get_default_channel_layout(spec.channels);
        if (!wanted_channel_layout) {
            fprintf(stderr, "SDL advised channel count %d is not supported!\n", spec.channels);
            return -1;
        }
    }
    
    audio_hw_params->fmt = AV_SAMPLE_FMT_S16;
    audio_hw_params->freq = spec.freq;
    audio_hw_params->channel_layout = wanted_channel_layout;
    audio_hw_params->channels =  spec.channels;
    return spec.size;
}

/* open a given stream. Return 0 if OK */
static int stream_component_open(VideoState *is, int stream_index)
{
    AVFormatContext *ic = is->ic;
    AVCodecContext *avctx;
    AVCodec *codec;
    AVDictionary *opts;
    AVDictionaryEntry *t = NULL;
    
    if (stream_index < 0 || stream_index >= ic->nb_streams)
        return -1;
    avctx = ic->streams[stream_index]->codec;
    
    codec = avcodec_find_decoder(avctx->codec_id);
    opts = filter_codec_opts(codec_opts, avctx->codec_id, ic, ic->streams[stream_index], codec);
    
    switch(avctx->codec_type){
        case AVMEDIA_TYPE_AUDIO   : is->last_audio_stream    = stream_index; if(audio_codec_name   ) codec= avcodec_find_decoder_by_name(   audio_codec_name); break;
        case AVMEDIA_TYPE_SUBTITLE: is->last_subtitle_stream = stream_index; if(subtitle_codec_name) codec= avcodec_find_decoder_by_name(subtitle_codec_name); break;
        case AVMEDIA_TYPE_VIDEO   : is->last_video_stream    = stream_index; if(video_codec_name   ) codec= avcodec_find_decoder_by_name(   video_codec_name); break;
    }
    if (!codec)
        return -1;
    
    avctx->workaround_bugs   = workaround_bugs;
    avctx->lowres            = lowres;
    if(avctx->lowres > codec->max_lowres){
        av_log(avctx, AV_LOG_WARNING, "The maximum value for lowres supported by the decoder is %d\n",
               codec->max_lowres);
        avctx->lowres= codec->max_lowres;
    }
    avctx->idct_algo         = idct;
    avctx->skip_frame        = skip_frame;
    avctx->skip_idct         = skip_idct;
    avctx->skip_loop_filter  = skip_loop_filter;
    avctx->error_concealment = error_concealment;
    
    if(avctx->lowres) avctx->flags |= CODEC_FLAG_EMU_EDGE;
    if (fast)   avctx->flags2 |= CODEC_FLAG2_FAST;
    if(codec->capabilities & CODEC_CAP_DR1)
        avctx->flags |= CODEC_FLAG_EMU_EDGE;
    
    if (!av_dict_get(opts, "threads", NULL, 0))
        av_dict_set(&opts, "threads", "auto", 0);
    if (!codec ||
        avcodec_open2(avctx, codec, &opts) < 0)
        return -1;
    if ((t = av_dict_get(opts, "", NULL, AV_DICT_IGNORE_SUFFIX))) {
        av_log(NULL, AV_LOG_ERROR, "Option %s not found.\n", t->key);
        return AVERROR_OPTION_NOT_FOUND;
    }
    
    /* prepare audio output */
    if (avctx->codec_type == AVMEDIA_TYPE_AUDIO) {
        int audio_hw_buf_size = audio_open(is, avctx->channel_layout, avctx->channels, avctx->sample_rate, &is->audio_src);
        if (audio_hw_buf_size < 0)
            return -1;
        is->audio_hw_buf_size = audio_hw_buf_size;
        is->audio_tgt = is->audio_src;
    }
    
    ic->streams[stream_index]->discard = AVDISCARD_DEFAULT;
    switch (avctx->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            is->audio_stream = stream_index;
            is->audio_st = ic->streams[stream_index];
            is->audio_buf_size  = 0;
            is->audio_buf_index = 0;
            
            /* init averaging filter */
            is->audio_diff_avg_coef  = exp(log(0.01) / AUDIO_DIFF_AVG_NB);
            is->audio_diff_avg_count = 0;
            /* since we do not have a precise anough audio fifo fullness,
             we correct audio sync only if larger than this threshold */
            is->audio_diff_threshold = 2.0 * is->audio_hw_buf_size / av_samples_get_buffer_size(NULL, is->audio_tgt.channels, is->audio_tgt.freq, is->audio_tgt.fmt, 1);
            
            memset(&is->audio_pkt, 0, sizeof(is->audio_pkt));
            memset(&is->audio_pkt_temp, 0, sizeof(is->audio_pkt_temp));
            packet_queue_start(&is->audioq);
            SDL_PauseAudio(0);
            break;
        case AVMEDIA_TYPE_VIDEO:
            is->video_stream = stream_index;
            is->video_st = ic->streams[stream_index];
            
            packet_queue_start(&is->videoq);
            is->video_tid = SDL_CreateThread(video_thread,"video_tid",  is);
            break;
        case AVMEDIA_TYPE_SUBTITLE:
//            is->subtitle_stream = stream_index;
//            is->subtitle_st = ic->streams[stream_index];
//            packet_queue_start(&is->subtitleq);
//            
//            is->subtitle_tid = SDL_CreateThread(subtitle_thread,"subtitle_tid",  is);
            break;
        default:
            break;
    }
    return 0;
}

static void stream_component_close(VideoState *is, int stream_index)
{
    AVFormatContext *ic = is->ic;
    AVCodecContext *avctx;
    
    if (stream_index < 0 || stream_index >= ic->nb_streams)
        return;
    avctx = ic->streams[stream_index]->codec;
    
    switch (avctx->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            packet_queue_abort(&is->audioq);
            
            SDL_CloseAudio();
            
            packet_queue_flush(&is->audioq);
            av_free_packet(&is->audio_pkt);
            swr_free(&is->swr_ctx);
            av_freep(&is->audio_buf1);
            is->audio_buf = NULL;
            avcodec_free_frame(&is->frame);
            
            if (is->rdft) {
                av_rdft_end(is->rdft);
                av_freep(&is->rdft_data);
                is->rdft = NULL;
                is->rdft_bits = 0;
            }
            break;
        case AVMEDIA_TYPE_VIDEO:
            packet_queue_abort(&is->videoq);
            
            /* note: we also signal this mutex to make sure we deblock the
             video thread in all cases */
            SDL_LockMutex(is->pictq_mutex);
            SDL_CondSignal(is->pictq_cond);
            SDL_UnlockMutex(is->pictq_mutex);
            
            SDL_WaitThread(is->video_tid, NULL);
            
            packet_queue_flush(&is->videoq);
            break;
        case AVMEDIA_TYPE_SUBTITLE:
            packet_queue_abort(&is->subtitleq);
            
            /* note: we also signal this mutex to make sure we deblock the
             video thread in all cases */
            SDL_LockMutex(is->subpq_mutex);
            is->subtitle_stream_changed = 1;
            
            SDL_CondSignal(is->subpq_cond);
            SDL_UnlockMutex(is->subpq_mutex);
            
            SDL_WaitThread(is->subtitle_tid, NULL);
            
            packet_queue_flush(&is->subtitleq);
            break;
        default:
            break;
    }
    
    ic->streams[stream_index]->discard = AVDISCARD_ALL;
    avcodec_close(avctx);
//#if CONFIG_AVFILTER
//    free_buffer_pool(&is->buffer_pool);
//#endif
    switch (avctx->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            is->audio_st = NULL;
            is->audio_stream = -1;
            break;
        case AVMEDIA_TYPE_VIDEO:
            is->video_st = NULL;
            is->video_stream = -1;
            break;
        case AVMEDIA_TYPE_SUBTITLE:
            is->subtitle_st = NULL;
            is->subtitle_stream = -1;
            break;
        default:
            break;
    }
}

static int decode_interrupt_cb(void *ctx)
{
    VideoState *is = ctx;
    return is->abort_request;
}

/* this thread gets the stream from the disk or the network */
static int read_thread(void *arg)
{
    VideoState *is = arg;
    AVFormatContext *ic = NULL;
    int err, i, ret;
    int st_index[AVMEDIA_TYPE_NB];
    AVPacket pkt1, *pkt = &pkt1;
    int eof = 0;
    int pkt_in_play_range = 0;
    AVDictionaryEntry *t;
    AVDictionary **opts;
    int orig_nb_streams;
    SDL_mutex *wait_mutex = SDL_CreateMutex();
    
    memset(st_index, -1, sizeof(st_index));
    is->last_video_stream = is->video_stream = -1;
    is->last_audio_stream = is->audio_stream = -1;
    is->last_subtitle_stream = is->subtitle_stream = -1;
    
    ic = avformat_alloc_context();
    ic->interrupt_callback.callback = decode_interrupt_cb;
    ic->interrupt_callback.opaque = is;
    err = avformat_open_input(&ic, is->filename, is->iformat, &format_opts);
    if (err < 0) {
        print_error(is->filename, err);
        ret = -1;
        goto fail;
    }
    if ((t = av_dict_get(format_opts, "", NULL, AV_DICT_IGNORE_SUFFIX))) {
        av_log(NULL, AV_LOG_ERROR, "Option %s not found.\n", t->key);
        ret = AVERROR_OPTION_NOT_FOUND;
        goto fail;
    }
    is->ic = ic;
    
    if (genpts)
        ic->flags |= AVFMT_FLAG_GENPTS;
    
    opts = setup_find_stream_info_opts(ic, codec_opts);
    orig_nb_streams = ic->nb_streams;
    
    err = avformat_find_stream_info(ic, opts);
    if (err < 0) {
        fprintf(stderr, "%s: could not find codec parameters\n", is->filename);
        ret = -1;
        goto fail;
    }
    for (i = 0; i < orig_nb_streams; i++)
        av_dict_free(&opts[i]);
    av_freep(&opts);
    
    if (ic->pb)
        ic->pb->eof_reached = 0; // FIXME hack, ffplay maybe should not use url_feof() to test for the end
    
    if (seek_by_bytes < 0)
        seek_by_bytes = !!(ic->iformat->flags & AVFMT_TS_DISCONT);
    
    /* if seeking requested, we execute it */
    if (start_time != AV_NOPTS_VALUE) {
        int64_t timestamp;
        
        timestamp = start_time;
        /* add the stream start time */
        if (ic->start_time != AV_NOPTS_VALUE)
            timestamp += ic->start_time;
        ret = avformat_seek_file(ic, -1, INT64_MIN, timestamp, INT64_MAX, 0);
        if (ret < 0) {
            fprintf(stderr, "%s: could not seek to position %0.3f\n",
                    is->filename, (double)timestamp / AV_TIME_BASE);
        }
    }
    
    for (i = 0; i < ic->nb_streams; i++)
        ic->streams[i]->discard = AVDISCARD_ALL;
    if (!video_disable)
        st_index[AVMEDIA_TYPE_VIDEO] =
        av_find_best_stream(ic, AVMEDIA_TYPE_VIDEO,
                            wanted_stream[AVMEDIA_TYPE_VIDEO], -1, NULL, 0);
    if (!audio_disable)
        st_index[AVMEDIA_TYPE_AUDIO] =
        av_find_best_stream(ic, AVMEDIA_TYPE_AUDIO,
                            wanted_stream[AVMEDIA_TYPE_AUDIO],
                            st_index[AVMEDIA_TYPE_VIDEO],
                            NULL, 0);
    if (!video_disable)
        st_index[AVMEDIA_TYPE_SUBTITLE] =
        av_find_best_stream(ic, AVMEDIA_TYPE_SUBTITLE,
                            wanted_stream[AVMEDIA_TYPE_SUBTITLE],
                            (st_index[AVMEDIA_TYPE_AUDIO] >= 0 ?
                             st_index[AVMEDIA_TYPE_AUDIO] :
                             st_index[AVMEDIA_TYPE_VIDEO]),
                            NULL, 0);
    if (show_status) {
        av_dump_format(ic, 0, is->filename, 0);
    }
    
    is->show_mode = show_mode;
    
    /* open the streams */
    if (st_index[AVMEDIA_TYPE_AUDIO] >= 0) {
        stream_component_open(is, st_index[AVMEDIA_TYPE_AUDIO]);
    }
    
    ret = -1;
    if (st_index[AVMEDIA_TYPE_VIDEO] >= 0) {
        ret = stream_component_open(is, st_index[AVMEDIA_TYPE_VIDEO]);
    }
    is->refresh_tid = SDL_CreateThread(refresh_thread, "refresh_tid",  is);
    if (is->show_mode == SHOW_MODE_NONE)
        is->show_mode = ret >= 0 ? SHOW_MODE_VIDEO : SHOW_MODE_RDFT;
    
    if (st_index[AVMEDIA_TYPE_SUBTITLE] >= 0) {
        stream_component_open(is, st_index[AVMEDIA_TYPE_SUBTITLE]);
    }
    
    if (is->video_stream < 0 && is->audio_stream < 0) {
        fprintf(stderr, "%s: could not open codecs\n", is->filename);
        ret = -1;
        goto fail;
    }
    
    for (;;) {
        if (is->abort_request)
            break;
        if (is->paused != is->last_paused) {
            is->last_paused = is->paused;
            if (is->paused)
                is->read_pause_return = av_read_pause(ic);
            else
                av_read_play(ic);
        }
#if CONFIG_RTSP_DEMUXER || CONFIG_MMSH_PROTOCOL
        if (is->paused &&
            (!strcmp(ic->iformat->name, "rtsp") ||
             (ic->pb && !strncmp(input_filename, "mmsh:", 5)))) {
                /* wait 10 ms to avoid trying to get another packet */
                /* XXX: horrible */
                SDL_Delay(10);
                continue;
            }
#endif
        if (is->seek_req) {
            int64_t seek_target = is->seek_pos;
            int64_t seek_min    = is->seek_rel > 0 ? seek_target - is->seek_rel + 2: INT64_MIN;
            int64_t seek_max    = is->seek_rel < 0 ? seek_target - is->seek_rel - 2: INT64_MAX;
            // FIXME the +-2 is due to rounding being not done in the correct direction in generation
            //      of the seek_pos/seek_rel variables
            
            ret = avformat_seek_file(is->ic, -1, seek_min, seek_target, seek_max, is->seek_flags);
            if (ret < 0) {
                fprintf(stderr, "%s: error while seeking\n", is->ic->filename);
            } else {
                if (is->audio_stream >= 0) {
                    packet_queue_flush(&is->audioq);
                    packet_queue_put(&is->audioq, &flush_pkt);
                }
                if (is->subtitle_stream >= 0) {
                    packet_queue_flush(&is->subtitleq);
                    packet_queue_put(&is->subtitleq, &flush_pkt);
                }
                if (is->video_stream >= 0) {
                    packet_queue_flush(&is->videoq);
                    packet_queue_put(&is->videoq, &flush_pkt);
                }
            }
            is->seek_req = 0;
            eof = 0;
        }
        if (is->que_attachments_req) {
            avformat_queue_attached_pictures(ic);
            is->que_attachments_req = 0;
        }
        
        /* if the queue are full, no need to read more */
        if (!infinite_buffer &&
            (is->audioq.size + is->videoq.size + is->subtitleq.size > MAX_QUEUE_SIZE
             || (   (is->audioq   .nb_packets > MIN_FRAMES || is->audio_stream < 0 || is->audioq.abort_request)
                 && (is->videoq   .nb_packets > MIN_FRAMES || is->video_stream < 0 || is->videoq.abort_request)
                 && (is->subtitleq.nb_packets > MIN_FRAMES || is->subtitle_stream < 0 || is->subtitleq.abort_request)))) {
                 /* wait 10 ms */
                 SDL_LockMutex(wait_mutex);
                 SDL_CondWaitTimeout(is->continue_read_thread, wait_mutex, 10);
                 SDL_UnlockMutex(wait_mutex);
                 continue;
             }
        if (eof) {
            if (is->video_stream >= 0) {
                av_init_packet(pkt);
                pkt->data = NULL;
                pkt->size = 0;
                pkt->stream_index = is->video_stream;
                packet_queue_put(&is->videoq, pkt);
            }
            if (is->audio_stream >= 0 &&
                is->audio_st->codec->codec->capabilities & CODEC_CAP_DELAY) {
                av_init_packet(pkt);
                pkt->data = NULL;
                pkt->size = 0;
                pkt->stream_index = is->audio_stream;
                packet_queue_put(&is->audioq, pkt);
            }
            SDL_Delay(10);
            if (is->audioq.size + is->videoq.size + is->subtitleq.size == 0) {
                if (loop != 1 && (!loop || --loop)) {
                    stream_seek(is, start_time != AV_NOPTS_VALUE ? start_time : 0, 0, 0);
                } else if (autoexit) {
                    ret = AVERROR_EOF;
                    goto fail;
                }
            }
            eof=0;
            continue;
        }
        ret = av_read_frame(ic, pkt);
        if (ret < 0) {
            if (ret == AVERROR_EOF || url_feof(ic->pb))
                eof = 1;
            if (ic->pb && ic->pb->error)
                break;
            SDL_LockMutex(wait_mutex);
            SDL_CondWaitTimeout(is->continue_read_thread, wait_mutex, 10);
            SDL_UnlockMutex(wait_mutex);
            continue;
        }
        /* check if packet is in play range specified by user, then queue, otherwise discard */
        pkt_in_play_range = duration == AV_NOPTS_VALUE ||
        (pkt->pts - ic->streams[pkt->stream_index]->start_time) *
        av_q2d(ic->streams[pkt->stream_index]->time_base) -
        (double)(start_time != AV_NOPTS_VALUE ? start_time : 0) / 1000000
        <= ((double)duration / 1000000);
        if (pkt->stream_index == is->audio_stream && pkt_in_play_range) {
            packet_queue_put(&is->audioq, pkt);
        } else if (pkt->stream_index == is->video_stream && pkt_in_play_range) {
            packet_queue_put(&is->videoq, pkt);
        } else if (pkt->stream_index == is->subtitle_stream && pkt_in_play_range) {
            packet_queue_put(&is->subtitleq, pkt);
        } else {
            av_free_packet(pkt);
        }
    }
    /* wait until the end */
    while (!is->abort_request) {
        SDL_Delay(100);
    }
    
    ret = 0;
fail:
    /* close each stream */
    if (is->audio_stream >= 0)
        stream_component_close(is, is->audio_stream);
    if (is->video_stream >= 0)
        stream_component_close(is, is->video_stream);
    if (is->subtitle_stream >= 0)
        stream_component_close(is, is->subtitle_stream);
    if (is->ic) {
        avformat_close_input(&is->ic);
    }
    
    if (ret != 0) {
        SDL_Event event;
        
        event.type = FF_QUIT_EVENT;
        event.user.data1 = is;
        SDL_PushEvent(&event);
    }
    SDL_DestroyMutex(wait_mutex);
    return 0;
}

static VideoState *stream_open(const char *filename, AVInputFormat *iformat)
{
    VideoState *is;
    
    is = av_mallocz(sizeof(VideoState));
    if (!is)
        return NULL;
    av_strlcpy(is->filename, filename, sizeof(is->filename));
    is->iformat = iformat;
    is->ytop    = 0;
    is->xleft   = 0;
    
    /* start video display */
    is->pictq_mutex = SDL_CreateMutex();
    is->pictq_cond  = SDL_CreateCond();
    
    is->subpq_mutex = SDL_CreateMutex();
    is->subpq_cond  = SDL_CreateCond();
    
    packet_queue_init(&is->videoq);
    packet_queue_init(&is->audioq);
    packet_queue_init(&is->subtitleq);
    
    is->continue_read_thread = SDL_CreateCond();
    
    //设置同步时钟为音频的时钟
    is->av_sync_type = av_sync_type;
    is->read_tid     = SDL_CreateThread(read_thread, "read_tid",  is);
    if (!is->read_tid) {
        av_free(is);
        return NULL;
    }
    return is;
}

static void stream_cycle_channel(VideoState *is, int codec_type)
{
    AVFormatContext *ic = is->ic;
    int start_index, stream_index;
    int old_index;
    AVStream *st;
    
    if (codec_type == AVMEDIA_TYPE_VIDEO) {
        start_index = is->last_video_stream;
        old_index = is->video_stream;
    } else if (codec_type == AVMEDIA_TYPE_AUDIO) {
        start_index = is->last_audio_stream;
        old_index = is->audio_stream;
    } else {
        start_index = is->last_subtitle_stream;
        old_index = is->subtitle_stream;
    }
    stream_index = start_index;
    for (;;) {
        if (++stream_index >= is->ic->nb_streams)
        {
            if (codec_type == AVMEDIA_TYPE_SUBTITLE)
            {
                stream_index = -1;
                is->last_subtitle_stream = -1;
                goto the_end;
            }
            if (start_index == -1)
                return;
            stream_index = 0;
        }
        if (stream_index == start_index)
            return;
        st = ic->streams[stream_index];
        if (st->codec->codec_type == codec_type) {
            /* check that parameters are OK */
            switch (codec_type) {
                case AVMEDIA_TYPE_AUDIO:
                    if (st->codec->sample_rate != 0 &&
                        st->codec->channels != 0)
                        goto the_end;
                    break;
                case AVMEDIA_TYPE_VIDEO:
                case AVMEDIA_TYPE_SUBTITLE:
                    goto the_end;
                default:
                    break;
            }
        }
    }
the_end:
    stream_component_close(is, old_index);
    stream_component_open(is, stream_index);
    if (codec_type == AVMEDIA_TYPE_VIDEO)
        is->que_attachments_req = 1;
}


static void toggle_full_screen(VideoState *is)
{
#if defined(__APPLE__) && SDL_VERSION_ATLEAST(1, 2, 14)
    /* OS X needs to reallocate the SDL overlays */
    int i;
    for (i = 0; i < VIDEO_PICTURE_QUEUE_SIZE; i++)
        is->pictq[i].reallocate = 1;
#endif
//    is_full_screen = !is_full_screen;
//    video_open(is, 1);
}

static void toggle_pause(VideoState *is)
{
    stream_toggle_pause(is);
    is->step = 0;
}

static void step_to_next_frame(VideoState *is)
{
    /* if the stream is paused unpause it, then step */
    if (is->paused)
        stream_toggle_pause(is);
    is->step = 1;
}

//static void toggle_audio_display(VideoState *is)
//{
//    int bgcolor = SDL_MapRGB(screen->format, 0x00, 0x00, 0x00);
//    is->show_mode = (is->show_mode + 1) % SHOW_MODE_NB;
//    fill_rectangle(screen,
//                   is->xleft, is->ytop, is->width, is->height,
//                   bgcolor);
//    SDL_UpdateRect(screen, is->xleft, is->ytop, is->width, is->height);
//}

/* handle an event sent by the GUI */
static void event_loop(VideoState *cur_stream)
{
    SDL_Event event;
    double incr, pos, frac;
    
    for (;;) {
        double x;
        SDL_WaitEvent(&event);
        switch (event.type) {
            case SDL_KEYDOWN:
                if (exit_on_keydown) {
                    do_exit(cur_stream);
                    break;
                }
                switch (event.key.keysym.sym) {
                    case SDLK_ESCAPE:
                    case SDLK_q:
                        do_exit(cur_stream);
                        break;
                    case SDLK_f:
                        toggle_full_screen(cur_stream);
                        cur_stream->force_refresh = 1;
                        break;
                    case SDLK_p:
                    case SDLK_SPACE:
                        toggle_pause(cur_stream);
                        break;
                    case SDLK_s: // S: Step to next frame
                        step_to_next_frame(cur_stream);
                        break;
                    case SDLK_a:
                        stream_cycle_channel(cur_stream, AVMEDIA_TYPE_AUDIO);
                        break;
                    case SDLK_v:
                        stream_cycle_channel(cur_stream, AVMEDIA_TYPE_VIDEO);
                        break;
                    case SDLK_t:
                        stream_cycle_channel(cur_stream, AVMEDIA_TYPE_SUBTITLE);
                        break;
//                    case SDLK_w:
//                        toggle_audio_display(cur_stream);
//                        cur_stream->force_refresh = 1;
//                        break;
                    case SDLK_PAGEUP:
                        incr = 600.0;
                        goto do_seek;
                    case SDLK_PAGEDOWN:
                        incr = -600.0;
                        goto do_seek;
                    case SDLK_LEFT:
                        incr = -10.0;
                        goto do_seek;
                    case SDLK_RIGHT:
                        incr = 10.0;
                        goto do_seek;
                    case SDLK_UP:
                        incr = 60.0;
                        goto do_seek;
                    case SDLK_DOWN:
                        incr = -60.0;
                    do_seek:
                        if (seek_by_bytes) {
                            if (cur_stream->video_stream >= 0 && cur_stream->video_current_pos >= 0) {
                                pos = cur_stream->video_current_pos;
                            } else if (cur_stream->audio_stream >= 0 && cur_stream->audio_pkt.pos >= 0) {
                                pos = cur_stream->audio_pkt.pos;
                            } else
                                pos = avio_tell(cur_stream->ic->pb);
                            if (cur_stream->ic->bit_rate)
                                incr *= cur_stream->ic->bit_rate / 8.0;
                            else
                                incr *= 180000.0;
                            pos += incr;
                            stream_seek(cur_stream, pos, incr, 1);
                        } else {
                            pos = get_master_clock(cur_stream);
                            pos += incr;
                            stream_seek(cur_stream, (int64_t)(pos * AV_TIME_BASE), (int64_t)(incr * AV_TIME_BASE), 0);
                        }
                        break;
                    default:
                        break;
                }
                break;
            case SDL_VIDEOEXPOSE:
                cur_stream->force_refresh = 1;
                break;
            case SDL_MOUSEBUTTONDOWN:
                if (exit_on_mousedown) {
                    do_exit(cur_stream);
                    break;
                }
            case SDL_MOUSEMOTION:
                if (event.type == SDL_MOUSEBUTTONDOWN) {
                    x = event.button.x;
                } else {
                    if (event.motion.state != SDL_PRESSED)
                        break;
                    x = event.motion.x;
                }
                if (seek_by_bytes || cur_stream->ic->duration <= 0) {
                    uint64_t size =  avio_size(cur_stream->ic->pb);
                    stream_seek(cur_stream, size*x/cur_stream->width, 0, 1);
                } else {
                    int64_t ts;
                    int ns, hh, mm, ss;
                    int tns, thh, tmm, tss;
                    tns  = cur_stream->ic->duration / 1000000LL;
                    thh  = tns / 3600;
                    tmm  = (tns % 3600) / 60;
                    tss  = (tns % 60);
                    frac = x / cur_stream->width;
                    ns   = frac * tns;
                    hh   = ns / 3600;
                    mm   = (ns % 3600) / 60;
                    ss   = (ns % 60);
                    fprintf(stderr, "Seek to %2.0f%% (%2d:%02d:%02d) of total duration (%2d:%02d:%02d)       \n", frac*100,
                            hh, mm, ss, thh, tmm, tss);
                    ts = frac * cur_stream->ic->duration;
                    if (cur_stream->ic->start_time != AV_NOPTS_VALUE)
                        ts += cur_stream->ic->start_time;
                    stream_seek(cur_stream, ts, 0, 0);
                }
                break;
            case SDL_VIDEORESIZE:
                NSLog(@"也执行这里了么？%s  %d", __FUNCTION__, __LINE__);
//                screen = SDL_SetVideoMode(event.resize.w, event.resize.h, 0,
//                                          SDL_HWSURFACE|SDL_RESIZABLE|SDL_ASYNCBLIT|SDL_HWACCEL);
//                screen = SDL_SetVideoMode(event.resize.w, event.resize.h, 0,
//                                          SDL_FULLSCREEN);
                screen_width  = cur_stream->width  = event.resize.w;
                screen_height = cur_stream->height = event.resize.h;
                cur_stream->force_refresh = 1;
                break;
            case SDL_QUIT:
            case FF_QUIT_EVENT:
                do_exit(cur_stream);
                break;
            case FF_ALLOC_EVENT:
                alloc_picture(event.user.data1);
                break;
            case FF_REFRESH_EVENT:
                video_refresh(event.user.data1);
                cur_stream->refresh = 0;
                break;
            default:
                break;
        }
    }
}

static int lockmgr(void **mtx, enum AVLockOp op)
{
    switch(op) {
        case AV_LOCK_CREATE:
            *mtx = SDL_CreateMutex();
            if(!*mtx)
                return 1;
            return 0;
        case AV_LOCK_OBTAIN:
            return !!SDL_LockMutex(*mtx);
        case AV_LOCK_RELEASE:
            return !!SDL_UnlockMutex(*mtx);
        case AV_LOCK_DESTROY:
            SDL_DestroyMutex(*mtx);
            return 0;
    }
    return 1;
}


- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        // Custom initialization
    }
    return self;
}

- (void)didReceiveMemoryWarning
{
    // Releases the view if it doesn't have a superview.
    [super didReceiveMemoryWarning];
    
    // Release any cached data, images, etc that aren't in use.
}

#pragma mark - View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.
    
    kxMoviedecoder = [[KxMovieDecoder alloc] init];
    
    UIView *frameView = [self frameView];
    frameView.contentMode = UIViewContentModeScaleAspectFit;
    frameView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleBottomMargin;
    
    [self.view addSubview:frameView];
}

- (void)viewDidAppear:(BOOL)animated {
    [self startPlay];

}

- (void)viewDidUnload
{
    [super viewDidUnload];
    // Release any retained subviews of the main view.
    // e.g. self.myOutlet = nil;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    // Return YES for supported orientations
	return YES;
}

const int program_birth_year = 2003;
const char program_name[] = "ffplay";

- (void)startPlay {
        
    int flags;
    VideoState *is;
    char dummy_videodriver[] = "SDL_VIDEODRIVER=dummy";
    
    input_filename = [[[NSBundle mainBundle] pathForResource:@"1" ofType:@"mp4"] UTF8String];
//    input_filename = "udp://@192.168.1.102:8905?fifo_size=1000000&overrun_nonfatal=1&buffer_size=102400&pkt_size=102400";


    display_disable = NO;

    av_log_set_flags(AV_LOG_SKIP_REPEATED);
    //parse_loglevel(argc, argv, options);
    
    /* register all codecs, demux and protocols */
    avcodec_register_all();
#if CONFIG_AVDEVICE
    avdevice_register_all();
#endif
//#if CONFIG_AVFILTER
//    avfilter_register_all();
//#endif
    av_register_all();
    avformat_network_init();
    
    init_opts();
    
    signal(SIGINT , sigterm_handler); /* Interrupt (ANSI).    */
    signal(SIGTERM, sigterm_handler); /* Termination (ANSI).  */
    
    if (!input_filename) {
//        show_usage();
//        fprintf(stderr, "An input file must be specified\n");
////        fprintf(stderr, "Use -h to get full help or, even better, run 'man %s'\n", program_name);
//        exit(1);
    }

    if (display_disable) {
        video_disable = 1;
    } else {
        video_disable = 0;
    }
    flags = SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_TIMER;
    if (audio_disable)
        flags &= ~SDL_INIT_AUDIO;
    if (display_disable)
        SDL_putenv(dummy_videodriver); /* For the event queue, we always need a video driver. */
#if !defined(__MINGW32__) && !defined(__APPLE__)
    flags |= SDL_INIT_EVENTTHREAD; /* Not supported on Windows or Mac OS X */
#endif
    if (SDL_Init (flags)) {
        fprintf(stderr, "Could not initialize SDL - %s\n", SDL_GetError());
        fprintf(stderr, "(Did you set the DISPLAY variable?)\n");
        exit(1);
    }
    
    if (!display_disable) {
#if HAVE_SDL_VIDEO_SIZE
        const SDL_VideoInfo *vi = SDL_GetVideoInfo();
        fs_screen_width = vi->current_w;
        fs_screen_height = vi->current_h;
#endif
    }
    
    SDL_EventState(SDL_ACTIVEEVENT, SDL_IGNORE);
    SDL_EventState(SDL_SYSWMEVENT, SDL_IGNORE);
    SDL_EventState(SDL_USEREVENT, SDL_IGNORE);
    
    if (av_lockmgr_register(lockmgr)) {
        fprintf(stderr, "Could not initialize lock manager!\n");
        do_exit(NULL);
    }
    
    av_init_packet(&flush_pkt);
    flush_pkt.data = (uint8_t *)(intptr_t)"FLUSH";
    
    is = stream_open(input_filename, file_iformat);
    if (!is) {
        fprintf(stderr, "Failed to initialize VideoState!\n");
        do_exit(NULL);
    }

//    [self performSelectorInBackground:@selector(showVideoThread) withObject:nil];
    //[self performSelectorInBackground:@selector(showVideoThread) withObject:nil];
    
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(showVideoThread) userInfo:NULL repeats:YES];
    
    
    event_loop(is);
}
- (void)showVideoThread {

    @synchronized (kxVideoFrame) {
        if (kxVideoFrame) {
            
            [_glView render:kxVideoFrame];
            [kxVideoFrame release];
            kxVideoFrame = nil;
            
        }
    }


}
- (UIView *) frameView
{
    if (!_glView) {
        _glView = [[KxMovieGLView alloc] initWithFrame:self.view.bounds decoder:nil];
    }
    return _glView;
}

@end
