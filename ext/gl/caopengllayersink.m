/*
 * GStreamer
 * Copyright (C) 2015 Matthew Waters <matthew@centricular.com>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public
 * License along with this library; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

/**
 * SECTION:element-caopengllayersink
 *
 * caopengllayersink renders incoming video frames to CAOpenGLLayer that
 * can be retreived through the layer property and placed in the Core
 * Animation render tree.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "caopengllayersink.h"
#include <QuartzCore/QuartzCore.h>

GST_DEBUG_CATEGORY (gst_debug_ca_sink);
#define GST_CAT_DEFAULT gst_debug_ca_sink

#define GST_CA_OPENGL_LAYER_SINK_GET_LOCK(glsink) \
  (GST_CA_OPENGL_LAYER_SINK(glsink)->drawing_lock)
#define GST_CA_OPENGL_LAYER_SINK_LOCK(glsink) \
  (g_mutex_lock(&GST_CA_OPENGL_LAYER_SINK_GET_LOCK (glsink)))
#define GST_CA_OPENGL_LAYER_SINK_UNLOCK(glsink) \
  (g_mutex_unlock(&GST_CA_OPENGL_LAYER_SINK_GET_LOCK (glsink)))

#define USING_OPENGL(context) (gst_gl_context_check_gl_version (context, GST_GL_API_OPENGL, 1, 0))
#define USING_OPENGL3(context) (gst_gl_context_check_gl_version (context, GST_GL_API_OPENGL3, 3, 1))
#define USING_GLES(context) (gst_gl_context_check_gl_version (context, GST_GL_API_GLES, 1, 0))
#define USING_GLES2(context) (gst_gl_context_check_gl_version (context, GST_GL_API_GLES2, 2, 0))
#define USING_GLES3(context) (gst_gl_context_check_gl_version (context, GST_GL_API_GLES2, 3, 0))

#define SUPPORTED_GL_APIS GST_GL_API_OPENGL | GST_GL_API_GLES2 | GST_GL_API_OPENGL3

static void gst_ca_opengl_layer_sink_thread_init_redisplay (GstCAOpenGLLayerSink * ca_sink);
static void gst_ca_opengl_layer_sink_cleanup_glthread (GstCAOpenGLLayerSink * ca_sink);
static void gst_ca_opengl_layer_sink_on_resize (GstCAOpenGLLayerSink * ca_sink,
    gint width, gint height);
static void gst_ca_opengl_layer_sink_on_draw (GstCAOpenGLLayerSink * ca_sink);

static void gst_ca_opengl_layer_sink_finalize (GObject * object);
static void gst_ca_opengl_layer_sink_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * param_spec);
static void gst_ca_opengl_layer_sink_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * param_spec);

static gboolean gst_ca_opengl_layer_sink_stop (GstBaseSink * bsink);

static gboolean gst_ca_opengl_layer_sink_query (GstBaseSink * bsink, GstQuery * query);
static void gst_ca_opengl_layer_sink_set_context (GstElement * element,
    GstContext * context);

static GstStateChangeReturn gst_ca_opengl_layer_sink_change_state (GstElement *
    element, GstStateChange transition);

static void gst_ca_opengl_layer_sink_get_times (GstBaseSink * bsink, GstBuffer * buf,
    GstClockTime * start, GstClockTime * end);
static gboolean gst_ca_opengl_layer_sink_set_caps (GstBaseSink * bsink, GstCaps * caps);
static GstFlowReturn gst_ca_opengl_layer_sink_prepare (GstBaseSink * bsink,
    GstBuffer * buf);
static GstFlowReturn gst_ca_opengl_layer_sink_show_frame (GstVideoSink * bsink,
    GstBuffer * buf);
static gboolean gst_ca_opengl_layer_sink_propose_allocation (GstBaseSink * bsink,
    GstQuery * query);

static GstStaticPadTemplate gst_ca_opengl_layer_sink_template =
    GST_STATIC_PAD_TEMPLATE ("sink",
    GST_PAD_SINK,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE_WITH_FEATURES
        (GST_CAPS_FEATURE_MEMORY_GL_MEMORY,
            "RGBA") "; "
        GST_VIDEO_CAPS_MAKE_WITH_FEATURES
        (GST_CAPS_FEATURE_META_GST_VIDEO_GL_TEXTURE_UPLOAD_META,
            "RGBA") "; " GST_VIDEO_CAPS_MAKE (GST_GL_COLOR_CONVERT_FORMATS))
    );

enum
{
  PROP_0,
  PROP_FORCE_ASPECT_RATIO,
  PROP_CONTEXT,
  PROP_LAYER,
};

#define gst_ca_opengl_layer_sink_parent_class parent_class
G_DEFINE_TYPE_WITH_CODE (GstCAOpenGLLayerSink, gst_ca_opengl_layer_sink,
    GST_TYPE_VIDEO_SINK, GST_DEBUG_CATEGORY_INIT (gst_debug_ca_sink,
        "caopengllayersink", 0, "CAOpenGLLayer Video Sink"));

static void
gst_ca_opengl_layer_sink_class_init (GstCAOpenGLLayerSinkClass * klass)
{
  GObjectClass *gobject_class;
  GstElementClass *gstelement_class;
  GstBaseSinkClass *gstbasesink_class;
  GstVideoSinkClass *gstvideosink_class;
  GstElementClass *element_class;

  gobject_class = (GObjectClass *) klass;
  gstelement_class = (GstElementClass *) klass;
  gstbasesink_class = (GstBaseSinkClass *) klass;
  gstvideosink_class = (GstVideoSinkClass *) klass;
  element_class = GST_ELEMENT_CLASS (klass);

  gobject_class->set_property = gst_ca_opengl_layer_sink_set_property;
  gobject_class->get_property = gst_ca_opengl_layer_sink_get_property;

  g_object_class_install_property (gobject_class, PROP_FORCE_ASPECT_RATIO,
      g_param_spec_boolean ("force-aspect-ratio",
          "Force aspect ratio",
          "When enabled, scaling will respect original aspect ratio", TRUE,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_CONTEXT,
      g_param_spec_object ("context",
          "OpenGL context",
          "Get OpenGL context",
          GST_GL_TYPE_CONTEXT, G_PARAM_READABLE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_LAYER,
      g_param_spec_pointer ("layer", "CAOpenGLLayer",
          "OpenGL Core Animation layer",
          G_PARAM_READABLE | G_PARAM_STATIC_STRINGS));

  gst_element_class_set_metadata (element_class, "CAOpenGLLayer video sink",
      "Sink/Video", "A video sink based on CAOpenGLLayer",
      "Matthew Waters <matthew@centricular.com>");

  gst_element_class_add_pad_template (element_class,
      gst_static_pad_template_get (&gst_ca_opengl_layer_sink_template));

  gobject_class->finalize = gst_ca_opengl_layer_sink_finalize;

  gstelement_class->change_state = gst_ca_opengl_layer_sink_change_state;
  gstelement_class->set_context = gst_ca_opengl_layer_sink_set_context;
  gstbasesink_class->query = GST_DEBUG_FUNCPTR (gst_ca_opengl_layer_sink_query);
  gstbasesink_class->set_caps = gst_ca_opengl_layer_sink_set_caps;
  gstbasesink_class->get_times = gst_ca_opengl_layer_sink_get_times;
  gstbasesink_class->prepare = gst_ca_opengl_layer_sink_prepare;
  gstbasesink_class->propose_allocation = gst_ca_opengl_layer_sink_propose_allocation;
  gstbasesink_class->stop = gst_ca_opengl_layer_sink_stop;

  gstvideosink_class->show_frame =
      GST_DEBUG_FUNCPTR (gst_ca_opengl_layer_sink_show_frame);
}

static void
gst_ca_opengl_layer_sink_init (GstCAOpenGLLayerSink * ca_sink)
{
  ca_sink->display = NULL;
  ca_sink->keep_aspect_ratio = TRUE;
  ca_sink->pool = NULL;
  ca_sink->stored_buffer = NULL;
  ca_sink->redisplay_texture = 0;

  g_mutex_init (&ca_sink->drawing_lock);
}

static void
gst_ca_opengl_layer_sink_finalize (GObject * object)
{
  GstCAOpenGLLayerSink *ca_sink;

  g_return_if_fail (GST_IS_CA_OPENGL_LAYER_SINK (object));

  ca_sink = GST_CA_OPENGL_LAYER_SINK (object);

  g_mutex_clear (&ca_sink->drawing_lock);

  GST_DEBUG ("finalized");
  G_OBJECT_CLASS (parent_class)->finalize (object);
}

static void
gst_ca_opengl_layer_sink_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstCAOpenGLLayerSink *ca_sink;

  g_return_if_fail (GST_IS_CA_OPENGL_LAYER_SINK (object));

  ca_sink = GST_CA_OPENGL_LAYER_SINK (object);

  switch (prop_id) {
    case PROP_FORCE_ASPECT_RATIO:
    {
      ca_sink->keep_aspect_ratio = g_value_get_boolean (value);
      break;
    }
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

static void
gst_ca_opengl_layer_sink_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * pspec)
{
  GstCAOpenGLLayerSink *ca_sink;

  g_return_if_fail (GST_IS_CA_OPENGL_LAYER_SINK (object));

  ca_sink = GST_CA_OPENGL_LAYER_SINK (object);

  switch (prop_id) {
    case PROP_FORCE_ASPECT_RATIO:
      g_value_set_boolean (value, ca_sink->keep_aspect_ratio);
      break;
    case PROP_CONTEXT:
      g_value_set_object (value, ca_sink->context);
      break;
    case PROP_LAYER:
      g_value_set_pointer (value, ca_sink->layer);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

static void
_create_layer (gpointer data)
{
  GstCAOpenGLLayerSink *ca_sink = data;

  if (!ca_sink->layer) {
    ca_sink->layer = [[NSClassFromString(@"GstGLCAOpenGLLayer") alloc]
        initWithGstGLContext:GST_GL_CONTEXT_COCOA (ca_sink->context)];
    [ca_sink->layer setDrawCallback:(GstGLWindowCB)gst_ca_opengl_layer_sink_on_draw
        data:ca_sink notify:NULL];
    [ca_sink->layer setResizeCallback:(GstGLWindowResizeCB)gst_ca_opengl_layer_sink_on_resize
        data:ca_sink notify:NULL];
    g_object_notify (G_OBJECT (ca_sink), "layer");
  }
}

static void
_invoke_on_main (GstGLWindowCB func, gpointer data)
{
  if ([NSThread isMainThread]) {
    func (data);
  } else {
    dispatch_sync (dispatch_get_main_queue (), ^{
      func (data);
    });
  }
}

static gboolean
_ensure_gl_setup (GstCAOpenGLLayerSink * ca_sink)
{
  GError *error = NULL;

  g_assert (![NSThread isMainThread]);

  if (!gst_gl_ensure_element_data (ca_sink, &ca_sink->display,
          &ca_sink->other_context))
    return FALSE;

  gst_gl_display_filter_gl_api (ca_sink->display, SUPPORTED_GL_APIS);

  if (!ca_sink->context) {
    ca_sink->context = gst_gl_context_new (ca_sink->display);
    if (!ca_sink->context)
      goto context_creation_error;

    if (!gst_gl_context_create (ca_sink->context, ca_sink->other_context,
            &error)) {
      goto context_error;
    }
  }

  if (!ca_sink->layer)
    _invoke_on_main ((GstGLWindowCB) _create_layer, ca_sink);

  return TRUE;

context_creation_error:
  {
    GST_ELEMENT_ERROR (ca_sink, RESOURCE, NOT_FOUND,
        ("Failed to create GL context"), (NULL));
    return FALSE;
  }

context_error:
  {
    GST_ELEMENT_ERROR (ca_sink, RESOURCE, NOT_FOUND, ("%s", error->message),
        (NULL));
    gst_object_unref (ca_sink->context);
    ca_sink->context = NULL;
    return FALSE;
  }
}

static gboolean
gst_ca_opengl_layer_sink_query (GstBaseSink * bsink, GstQuery * query)
{
  GstCAOpenGLLayerSink *ca_sink = GST_CA_OPENGL_LAYER_SINK (bsink);
  gboolean res = FALSE;

  switch (GST_QUERY_TYPE (query)) {
    case GST_QUERY_CONTEXT:
    {
      gboolean ret =
          gst_gl_handle_context_query ((GstElement *) ca_sink, query,
          &ca_sink->display, &ca_sink->other_context);
      if (ca_sink->display)
        gst_gl_display_filter_gl_api (ca_sink->display, SUPPORTED_GL_APIS);
      return ret;
    }
    case GST_QUERY_DRAIN:
    {
      GstBuffer *buf = NULL;

      GST_CA_OPENGL_LAYER_SINK_LOCK (ca_sink);
      ca_sink->redisplay_texture = 0;
      buf = ca_sink->stored_buffer;
      ca_sink->stored_buffer = NULL;
      GST_CA_OPENGL_LAYER_SINK_UNLOCK (ca_sink);

      if (buf)
        gst_buffer_unref (buf);

      gst_buffer_replace (&ca_sink->next_buffer, NULL);
      gst_gl_upload_release_buffer (ca_sink->upload);

      res = GST_BASE_SINK_CLASS (parent_class)->query (bsink, query);
      break;
    }
    default:
      res = GST_BASE_SINK_CLASS (parent_class)->query (bsink, query);
      break;
  }

  return res;
}

static gboolean
gst_ca_opengl_layer_sink_stop (GstBaseSink * bsink)
{
  GstCAOpenGLLayerSink *ca_sink = GST_CA_OPENGL_LAYER_SINK (bsink);

  if (ca_sink->pool) {
    gst_object_unref (ca_sink->pool);
    ca_sink->pool = NULL;
  }

  if (ca_sink->gl_caps) {
    gst_caps_unref (ca_sink->gl_caps);
    ca_sink->gl_caps = NULL;
  }

  return TRUE;
}

static void
gst_ca_opengl_layer_sink_set_context (GstElement * element, GstContext * context)
{
  GstCAOpenGLLayerSink *ca_sink = GST_CA_OPENGL_LAYER_SINK (element);

  gst_gl_handle_set_context (element, context, &ca_sink->display,
      &ca_sink->other_context);

  if (ca_sink->display)
    gst_gl_display_filter_gl_api (ca_sink->display, SUPPORTED_GL_APIS);
}

static GstStateChangeReturn
gst_ca_opengl_layer_sink_change_state (GstElement * element, GstStateChange transition)
{
  GstCAOpenGLLayerSink *ca_sink;
  GstStateChangeReturn ret = GST_STATE_CHANGE_SUCCESS;

  GST_DEBUG ("changing state: %s => %s",
      gst_element_state_get_name (GST_STATE_TRANSITION_CURRENT (transition)),
      gst_element_state_get_name (GST_STATE_TRANSITION_NEXT (transition)));

  ca_sink = GST_CA_OPENGL_LAYER_SINK (element);

  switch (transition) {
    case GST_STATE_CHANGE_NULL_TO_READY:
      break;
    case GST_STATE_CHANGE_READY_TO_PAUSED:
      g_atomic_int_set (&ca_sink->to_quit, 0);
      break;
    case GST_STATE_CHANGE_PAUSED_TO_PLAYING:
      break;
    default:
      break;
  }

  ret = GST_ELEMENT_CLASS (parent_class)->change_state (element, transition);
  if (ret == GST_STATE_CHANGE_FAILURE)
    return ret;

  switch (transition) {
    case GST_STATE_CHANGE_PLAYING_TO_PAUSED:
      break;
    case GST_STATE_CHANGE_PAUSED_TO_READY:
    {
      /* mark the redisplay_texture as unavailable (=0)
       * to avoid drawing
       */
      GST_CA_OPENGL_LAYER_SINK_LOCK (ca_sink);
      ca_sink->redisplay_texture = 0;
      if (ca_sink->stored_buffer) {
        gst_buffer_unref (ca_sink->stored_buffer);
        ca_sink->stored_buffer = NULL;
      }
      GST_CA_OPENGL_LAYER_SINK_UNLOCK (ca_sink);
      gst_buffer_replace (&ca_sink->next_buffer, NULL);

      if (ca_sink->upload) {
        gst_object_unref (ca_sink->upload);
        ca_sink->upload = NULL;
      }

      if (ca_sink->convert) {
        gst_object_unref (ca_sink->convert);
        ca_sink->convert = NULL;
      }

      if (ca_sink->pool) {
        gst_buffer_pool_set_active (ca_sink->pool, FALSE);
        gst_object_unref (ca_sink->pool);
        ca_sink->pool = NULL;
      }

      GST_VIDEO_SINK_WIDTH (ca_sink) = 1;
      GST_VIDEO_SINK_HEIGHT (ca_sink) = 1;
      if (ca_sink->context) {
        gst_object_unref (ca_sink->context);
        ca_sink->context = NULL;
      }

      if (ca_sink->display) {
        gst_object_unref (ca_sink->display);
        ca_sink->display = NULL;
      }
      break;
    }
    case GST_STATE_CHANGE_READY_TO_NULL:
      break;
    default:
      break;
  }

  return ret;
}

static void
gst_ca_opengl_layer_sink_get_times (GstBaseSink * bsink, GstBuffer * buf,
    GstClockTime * start, GstClockTime * end)
{
  GstCAOpenGLLayerSink *ca_sink;

  ca_sink = GST_CA_OPENGL_LAYER_SINK (bsink);

  if (GST_BUFFER_TIMESTAMP_IS_VALID (buf)) {
    *start = GST_BUFFER_TIMESTAMP (buf);
    if (GST_BUFFER_DURATION_IS_VALID (buf))
      *end = *start + GST_BUFFER_DURATION (buf);
    else {
      if (GST_VIDEO_INFO_FPS_N (&ca_sink->info) > 0) {
        *end = *start +
            gst_util_uint64_scale_int (GST_SECOND,
            GST_VIDEO_INFO_FPS_D (&ca_sink->info),
            GST_VIDEO_INFO_FPS_N (&ca_sink->info));
      }
    }
  }
}

static gboolean
gst_ca_opengl_layer_sink_set_caps (GstBaseSink * bsink, GstCaps * caps)
{
  GstCAOpenGLLayerSink *ca_sink;
  gint width;
  gint height;
  gboolean ok;
  gint par_n, par_d;
  gint display_par_n, display_par_d;
  guint display_ratio_num, display_ratio_den;
  GstVideoInfo vinfo;
  GstStructure *structure;
  GstBufferPool *newpool, *oldpool;
  GstCapsFeatures *gl_features;
  GstCaps *uploaded_caps;

  GST_DEBUG ("set caps with %" GST_PTR_FORMAT, caps);

  ca_sink = GST_CA_OPENGL_LAYER_SINK (bsink);

  ok = gst_video_info_from_caps (&vinfo, caps);
  if (!ok)
    return FALSE;

  width = GST_VIDEO_INFO_WIDTH (&vinfo);
  height = GST_VIDEO_INFO_HEIGHT (&vinfo);

  par_n = GST_VIDEO_INFO_PAR_N (&vinfo);
  par_d = GST_VIDEO_INFO_PAR_D (&vinfo);

  if (!par_n)
    par_n = 1;

  display_par_n = 1;
  display_par_d = 1;

  ok = gst_video_calculate_display_ratio (&display_ratio_num,
      &display_ratio_den, width, height, par_n, par_d, display_par_n,
      display_par_d);

  if (!ok)
    return FALSE;

  GST_TRACE ("PAR: %u/%u DAR:%u/%u", par_n, par_d, display_par_n,
      display_par_d);

  if (height % display_ratio_den == 0) {
    GST_DEBUG ("keeping video height");
    GST_VIDEO_SINK_WIDTH (ca_sink) = (guint)
        gst_util_uint64_scale_int (height, display_ratio_num,
        display_ratio_den);
    GST_VIDEO_SINK_HEIGHT (ca_sink) = height;
  } else if (width % display_ratio_num == 0) {
    GST_DEBUG ("keeping video width");
    GST_VIDEO_SINK_WIDTH (ca_sink) = width;
    GST_VIDEO_SINK_HEIGHT (ca_sink) = (guint)
        gst_util_uint64_scale_int (width, display_ratio_den, display_ratio_num);
  } else {
    GST_DEBUG ("approximating while keeping video height");
    GST_VIDEO_SINK_WIDTH (ca_sink) = (guint)
        gst_util_uint64_scale_int (height, display_ratio_num,
        display_ratio_den);
    GST_VIDEO_SINK_HEIGHT (ca_sink) = height;
  }
  GST_DEBUG ("scaling to %dx%d", GST_VIDEO_SINK_WIDTH (ca_sink),
      GST_VIDEO_SINK_HEIGHT (ca_sink));

  ca_sink->info = vinfo;
  if (!_ensure_gl_setup (ca_sink))
    return FALSE;

  newpool = gst_gl_buffer_pool_new (ca_sink->context);
  structure = gst_buffer_pool_get_config (newpool);
  gst_buffer_pool_config_set_params (structure, caps, vinfo.size, 2, 0);
  gst_buffer_pool_set_config (newpool, structure);

  oldpool = ca_sink->pool;
  /* we don't activate the pool yet, this will be done by downstream after it
   * has configured the pool. If downstream does not want our pool we will
   * activate it when we render into it */
  ca_sink->pool = newpool;

  /* unref the old sink */
  if (oldpool) {
    /* we don't deactivate, some elements might still be using it, it will
     * be deactivated when the last ref is gone */
    gst_object_unref (oldpool);
  }

  if (ca_sink->upload)
    gst_object_unref (ca_sink->upload);
  ca_sink->upload = gst_gl_upload_new (ca_sink->context);

  gl_features =
      gst_caps_features_from_string (GST_CAPS_FEATURE_MEMORY_GL_MEMORY);

  uploaded_caps = gst_caps_copy (caps);
  gst_caps_set_features (uploaded_caps, 0,
      gst_caps_features_copy (gl_features));
  gst_gl_upload_set_caps (ca_sink->upload, caps, uploaded_caps);

  if (ca_sink->gl_caps)
    gst_caps_unref (ca_sink->gl_caps);
  ca_sink->gl_caps = gst_caps_copy (caps);
  gst_caps_set_simple (ca_sink->gl_caps, "format", G_TYPE_STRING, "RGBA",
      NULL);
  gst_caps_set_features (ca_sink->gl_caps, 0,
      gst_caps_features_copy (gl_features));

  if (ca_sink->convert)
    gst_object_unref (ca_sink->convert);
  ca_sink->convert = gst_gl_color_convert_new (ca_sink->context);
  if (!gst_gl_color_convert_set_caps (ca_sink->convert, uploaded_caps,
          ca_sink->gl_caps)) {
    gst_caps_unref (uploaded_caps);
    gst_caps_features_free (gl_features);
    return FALSE;
  }
  gst_caps_unref (uploaded_caps);
  gst_caps_features_free (gl_features);

  ca_sink->caps_change = TRUE;

  return TRUE;
}

static GstFlowReturn
gst_ca_opengl_layer_sink_prepare (GstBaseSink * bsink, GstBuffer * buf)
{
  GstCAOpenGLLayerSink *ca_sink;
  GstBuffer *uploaded_buffer, *next_buffer = NULL;
  GstVideoFrame gl_frame;
  GstVideoInfo gl_info;

  ca_sink = GST_CA_OPENGL_LAYER_SINK (bsink);

  GST_TRACE ("preparing buffer:%p", buf);

  if (GST_VIDEO_SINK_WIDTH (ca_sink) < 1 ||
      GST_VIDEO_SINK_HEIGHT (ca_sink) < 1) {
    return GST_FLOW_NOT_NEGOTIATED;
  }

  if (!_ensure_gl_setup (ca_sink))
    return GST_FLOW_NOT_NEGOTIATED;

  if (gst_gl_upload_perform_with_buffer (ca_sink->upload, buf,
          &uploaded_buffer) != GST_GL_UPLOAD_DONE)
    goto upload_failed;

  if (!(next_buffer =
          gst_gl_color_convert_perform (ca_sink->convert,
              uploaded_buffer))) {
    gst_buffer_unref (uploaded_buffer);
    goto upload_failed;
  }

  gst_video_info_from_caps (&gl_info, ca_sink->gl_caps);

  if (!gst_video_frame_map (&gl_frame, &gl_info, next_buffer,
          GST_MAP_READ | GST_MAP_GL)) {
    gst_buffer_unref (uploaded_buffer);
    gst_buffer_unref (next_buffer);
    goto upload_failed;
  }
  gst_buffer_unref (uploaded_buffer);

  ca_sink->next_tex = *(guint *) gl_frame.data[0];

  gst_buffer_replace (&ca_sink->next_buffer, next_buffer);
  gst_buffer_unref (next_buffer);

  gst_video_frame_unmap (&gl_frame);

  return GST_FLOW_OK;

upload_failed:
  {
    GST_ELEMENT_ERROR (ca_sink, RESOURCE, NOT_FOUND,
        ("%s", "Failed to upload buffer"), (NULL));
    return GST_FLOW_ERROR;
  }
}

static GstFlowReturn
gst_ca_opengl_layer_sink_show_frame (GstVideoSink * vsink, GstBuffer * buf)
{
  GstCAOpenGLLayerSink *ca_sink;
  GstBuffer *stored_buffer;

  GST_TRACE ("rendering buffer:%p", buf);

  ca_sink = GST_CA_OPENGL_LAYER_SINK (vsink);

  GST_TRACE ("redisplay texture:%u of size:%ux%u, window size:%ux%u",
      ca_sink->next_tex, GST_VIDEO_INFO_WIDTH (&ca_sink->info),
      GST_VIDEO_INFO_HEIGHT (&ca_sink->info),
      GST_VIDEO_SINK_WIDTH (ca_sink),
      GST_VIDEO_SINK_HEIGHT (ca_sink));

  /* Avoid to release the texture while drawing */
  GST_CA_OPENGL_LAYER_SINK_LOCK (ca_sink);
  ca_sink->redisplay_texture = ca_sink->next_tex;
  stored_buffer = ca_sink->stored_buffer;
  ca_sink->stored_buffer = gst_buffer_ref (ca_sink->next_buffer);
  GST_CA_OPENGL_LAYER_SINK_UNLOCK (ca_sink);

  /* The layer will automatically call the draw callback to draw the new
   * content */
  [CATransaction begin];
  [ca_sink->layer setNeedsDisplay];
  [CATransaction commit];

  GST_TRACE ("post redisplay");

  if (stored_buffer)
    gst_buffer_unref (stored_buffer);

  if (g_atomic_int_get (&ca_sink->to_quit) != 0) {
    GST_ELEMENT_ERROR (ca_sink, RESOURCE, NOT_FOUND,
        ("%s", gst_gl_context_get_error ()), (NULL));
    gst_gl_upload_release_buffer (ca_sink->upload);
    return GST_FLOW_ERROR;
  }

  return GST_FLOW_OK;
}

static gboolean
gst_ca_opengl_layer_sink_propose_allocation (GstBaseSink * bsink, GstQuery * query)
{
  GstCAOpenGLLayerSink *ca_sink = GST_CA_OPENGL_LAYER_SINK (bsink);
  GstBufferPool *pool;
  GstStructure *config;
  GstCaps *caps;
  guint size;
  gboolean need_pool;
  GstStructure *gl_context;
  gchar *platform, *gl_apis;
  gpointer handle;
  GstAllocator *allocator = NULL;
  GstAllocationParams params;

  if (!_ensure_gl_setup (ca_sink))
    return FALSE;

  gst_query_parse_allocation (query, &caps, &need_pool);

  if (caps == NULL)
    goto no_caps;

  if ((pool = ca_sink->pool))
    gst_object_ref (pool);

  if (pool != NULL) {
    GstCaps *pcaps;

    /* we had a pool, check caps */
    GST_DEBUG_OBJECT (ca_sink, "check existing pool caps");
    config = gst_buffer_pool_get_config (pool);
    gst_buffer_pool_config_get_params (config, &pcaps, &size, NULL, NULL);

    if (!gst_caps_is_equal (caps, pcaps)) {
      GST_DEBUG_OBJECT (ca_sink, "pool has different caps");
      /* different caps, we can't use this pool */
      gst_object_unref (pool);
      pool = NULL;
    }
    gst_structure_free (config);
  }

  if (pool == NULL && need_pool) {
    GstVideoInfo info;

    if (!gst_video_info_from_caps (&info, caps))
      goto invalid_caps;

    GST_DEBUG_OBJECT (ca_sink, "create new pool");
    pool = gst_gl_buffer_pool_new (ca_sink->context);

    /* the normal size of a frame */
    size = info.size;

    config = gst_buffer_pool_get_config (pool);
    gst_buffer_pool_config_set_params (config, caps, size, 0, 0);
    if (!gst_buffer_pool_set_config (pool, config))
      goto config_failed;
  }
  /* we need at least 2 buffer because we hold on to the last one */
  if (pool) {
    gst_query_add_allocation_pool (query, pool, size, 2, 0);
    gst_object_unref (pool);
  }

  /* we also support various metadata */
  gst_query_add_allocation_meta (query, GST_VIDEO_META_API_TYPE, 0);
  if (ca_sink->context->gl_vtable->FenceSync)
    gst_query_add_allocation_meta (query, GST_GL_SYNC_META_API_TYPE, 0);

  gl_apis =
      gst_gl_api_to_string (gst_gl_context_get_gl_api (ca_sink->context));
  platform =
      gst_gl_platform_to_string (gst_gl_context_get_gl_platform
      (ca_sink->context));
  handle = (gpointer) gst_gl_context_get_gl_context (ca_sink->context);

  gl_context =
      gst_structure_new ("GstVideoGLTextureUploadMeta", "gst.gl.GstGLContext",
      GST_GL_TYPE_CONTEXT, ca_sink->context, "gst.gl.context.handle",
      G_TYPE_POINTER, handle, "gst.gl.context.type", G_TYPE_STRING, platform,
      "gst.gl.context.apis", G_TYPE_STRING, gl_apis, NULL);
  gst_query_add_allocation_meta (query,
      GST_VIDEO_GL_TEXTURE_UPLOAD_META_API_TYPE, gl_context);

  g_free (gl_apis);
  g_free (platform);
  gst_structure_free (gl_context);

  gst_allocation_params_init (&params);

  allocator = gst_allocator_find (GST_GL_MEMORY_ALLOCATOR);
  gst_query_add_allocation_param (query, allocator, &params);
  gst_object_unref (allocator);

  return TRUE;

  /* ERRORS */
no_caps:
  {
    GST_DEBUG_OBJECT (bsink, "no caps specified");
    return FALSE;
  }
invalid_caps:
  {
    GST_DEBUG_OBJECT (bsink, "invalid caps specified");
    return FALSE;
  }
config_failed:
  {
    GST_DEBUG_OBJECT (bsink, "failed setting config");
    return FALSE;
  }
}

/* *INDENT-OFF* */
static const GLfloat vertices[] = {
     1.0f,  1.0f, 0.0f, 1.0f, 0.0f,
    -1.0f,  1.0f, 0.0f, 0.0f, 0.0f,
    -1.0f, -1.0f, 0.0f, 0.0f, 1.0f,
     1.0f, -1.0f, 0.0f, 1.0f, 1.0f
};
/* *INDENT-ON* */

static void
_bind_buffer (GstCAOpenGLLayerSink * ca_sink)
{
  const GstGLFuncs *gl = ca_sink->context->gl_vtable;

  gl->BindBuffer (GL_ARRAY_BUFFER, ca_sink->vertex_buffer);
  gl->BufferData (GL_ARRAY_BUFFER, 4 * 5 * sizeof (GLfloat), vertices,
      GL_STATIC_DRAW);

  /* Load the vertex position */
  gl->VertexAttribPointer (ca_sink->attr_position, 3, GL_FLOAT, GL_FALSE,
      5 * sizeof (GLfloat), (void *) 0);

  /* Load the texture coordinate */
  gl->VertexAttribPointer (ca_sink->attr_texture, 2, GL_FLOAT, GL_FALSE,
      5 * sizeof (GLfloat), (void *) (3 * sizeof (GLfloat)));

  gl->EnableVertexAttribArray (ca_sink->attr_position);
  gl->EnableVertexAttribArray (ca_sink->attr_texture);
}

static void
_unbind_buffer (GstCAOpenGLLayerSink * ca_sink)
{
  const GstGLFuncs *gl = ca_sink->context->gl_vtable;

  gl->BindBuffer (GL_ARRAY_BUFFER, 0);

  gl->DisableVertexAttribArray (ca_sink->attr_position);
  gl->DisableVertexAttribArray (ca_sink->attr_texture);
}

/* Called in the gl thread */
static void
gst_ca_opengl_layer_sink_thread_init_redisplay (GstCAOpenGLLayerSink * ca_sink)
{
  const GstGLFuncs *gl = ca_sink->context->gl_vtable;

  ca_sink->redisplay_shader = gst_gl_shader_new (ca_sink->context);

  if (!gst_gl_shader_compile_with_default_vf_and_check
      (ca_sink->redisplay_shader, &ca_sink->attr_position,
          &ca_sink->attr_texture))
    gst_ca_opengl_layer_sink_cleanup_glthread (ca_sink);

  if (gl->GenVertexArrays) {
    gl->GenVertexArrays (1, &ca_sink->vao);
    gl->BindVertexArray (ca_sink->vao);
  }

  gl->GenBuffers (1, &ca_sink->vertex_buffer);
  _bind_buffer (ca_sink);

  if (gl->GenVertexArrays) {
    gl->BindVertexArray (0);
    gl->BindBuffer (GL_ARRAY_BUFFER, 0);
  } else {
    _unbind_buffer (ca_sink);
  }
}

static void
gst_ca_opengl_layer_sink_cleanup_glthread (GstCAOpenGLLayerSink * ca_sink)
{
  const GstGLFuncs *gl = ca_sink->context->gl_vtable;

  if (ca_sink->redisplay_shader) {
    gst_object_unref (ca_sink->redisplay_shader);
    ca_sink->redisplay_shader = NULL;
  }

  if (ca_sink->vao) {
    gl->DeleteVertexArrays (1, &ca_sink->vao);
    ca_sink->vao = 0;
  }
}

static void
gst_ca_opengl_layer_sink_on_resize (GstCAOpenGLLayerSink * ca_sink, gint width, gint height)
{
  /* Here ca_sink members (ex:ca_sink->info) have a life time of set_caps.
   * It means that they cannot not change between two set_caps
   */
  const GstGLFuncs *gl = ca_sink->context->gl_vtable;

  GST_TRACE ("GL Window resized to %ux%u", width, height);

  width = MAX (1, width);
  height = MAX (1, height);

  ca_sink->window_width = width;
  ca_sink->window_height = height;

  /* default reshape */
  if (ca_sink->keep_aspect_ratio) {
    GstVideoRectangle src, dst, result;

    src.x = 0;
    src.y = 0;
    src.w = GST_VIDEO_SINK_WIDTH (ca_sink);
    src.h = GST_VIDEO_SINK_HEIGHT (ca_sink);

    dst.x = 0;
    dst.y = 0;
    dst.w = width;
    dst.h = height;

    gst_video_sink_center_rect (src, dst, &result, TRUE);
    gl->Viewport (result.x, result.y, result.w, result.h);
  } else {
    gl->Viewport (0, 0, width, height);
  }
}

static void
gst_ca_opengl_layer_sink_on_draw (GstCAOpenGLLayerSink * ca_sink)
{
  /* Here ca_sink members (ex:ca_sink->info) have a life time of set_caps.
   * It means that they cannot not change between two set_caps as well as
   * for the redisplay_texture size.
   * Whereas redisplay_texture id changes every sink_render
   */

  const GstGLFuncs *gl = NULL;
  GLushort indices[] = { 0, 1, 2, 0, 2, 3 };

  g_return_if_fail (GST_IS_CA_OPENGL_LAYER_SINK (ca_sink));

  gl = ca_sink->context->gl_vtable;

  GST_CA_OPENGL_LAYER_SINK_LOCK (ca_sink);

  if (G_UNLIKELY (!ca_sink->redisplay_shader)) {
    gst_ca_opengl_layer_sink_thread_init_redisplay (ca_sink);
  }

  /* check if texture is ready for being drawn */
  if (!ca_sink->redisplay_texture) {
    GST_CA_OPENGL_LAYER_SINK_UNLOCK (ca_sink);
    return;
  }

  /* opengl scene */
  GST_TRACE ("redrawing texture:%u", ca_sink->redisplay_texture);

  if (ca_sink->caps_change) {
    GST_CA_OPENGL_LAYER_SINK_UNLOCK (ca_sink);
    gst_ca_opengl_layer_sink_on_resize (ca_sink, ca_sink->window_width,
        ca_sink->window_height);
    GST_CA_OPENGL_LAYER_SINK_LOCK (ca_sink);
    ca_sink->caps_change = TRUE;
  }

#if GST_GL_HAVE_OPENGL
  if (USING_OPENGL (ca_sink->context))
    gl->Disable (GL_TEXTURE_2D);
#endif

  gl->BindTexture (GL_TEXTURE_2D, 0);

  gl->ClearColor (0.0, 0.0, 0.0, 0.0);
  gl->Clear (GL_COLOR_BUFFER_BIT);

  gst_gl_shader_use (ca_sink->redisplay_shader);

  if (gl->GenVertexArrays)
    gl->BindVertexArray (ca_sink->vao);
  else
    _bind_buffer (ca_sink);

  gl->ActiveTexture (GL_TEXTURE0);
  gl->BindTexture (GL_TEXTURE_2D, ca_sink->redisplay_texture);
  gst_gl_shader_set_uniform_1i (ca_sink->redisplay_shader, "tex", 0);

  gl->DrawElements (GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, indices);

  if (gl->GenVertexArrays)
    gl->BindVertexArray (0);
  else
    _unbind_buffer (ca_sink);

  /* end default opengl scene */
  GST_CA_OPENGL_LAYER_SINK_UNLOCK (ca_sink);
}